// Linux: GTK on X11 (or XWayland) for the island window, a Unix socket for
// the relay, XDG directories for files.
//
// Why X11: the island has to place itself at the top centre, stay above
// everything, read the global cursor and shape its input region. Wayland gives
// an ordinary client none of that. gtk-layer-shell would, but GNOME — the
// default desktop of Ubuntu and Fedora — does not implement layer-shell, and
// there every Wayland window lands wherever the compositor decides. XWayland,
// present on GNOME, KDE and most others, does the job everywhere.

use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use tauri::{AppHandle, Manager, WebviewWindow};
use tokio::net::{UnixListener, UnixStream};

use super::{Input, LocalTime};
use crate::island::{PANEL_W, STRIP_H, STRIP_W, WINDOW_LABEL};
use crate::log;
use crate::pipe::{handle, Relay};

/// What the front end is told, to pick wording that differs between systems.
pub const NAME: &str = "linux";

/// File name of the Claude Code relay.
pub const HOOK_EXE: &str = "coucou-hook";

/// Environment variable holding the home directory.
pub const HOME_VAR: &str = "HOME";

/// A hidden island keeps its full-size window and narrows its input to the
/// wake strip instead of shrinking (see `set_input`).
pub const SHRINKS_TO_STRIP: bool = false;

// ── Files ─────────────────────────────────────────────────────────────────────

/// An XDG base directory: the variable when it holds an absolute path (the spec
/// says relative ones must be ignored), `$HOME/<fallback>` otherwise.
fn xdg(var: &str, fallback: &str) -> PathBuf {
    std::env::var_os(var)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| super::home_dir().join(fallback))
}

/// $XDG_CONFIG_HOME/coucou (~/.config/coucou) — preferences.
pub fn config_dir() -> PathBuf {
    xdg("XDG_CONFIG_HOME", ".config").join("coucou")
}

/// $XDG_DATA_HOME/coucou (~/.local/share/coucou) — the relay, the inbox, the log.
pub fn local_dir() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share").join("coucou")
}

/// Runs before GTK starts and before any other thread exists.
///
/// - GTK is pointed at X11 (see the note at the top). Anyone who sets
///   GDK_BACKEND themselves keeps their choice.
/// - WebKitGTK's DMA-BUF renderer draws transparent windows black or blank on a
///   number of drivers (NVIDIA above all); the island is small, so the fallback
///   renderer costs nothing noticeable.
/// - Inside an AppImage, GStreamer would otherwise keep its plugin registry in
///   ~/.cache/gstreamer-1.0, the same file the system's GStreamer uses, and
///   rewrite it on every launch with plugin paths from a mount that vanishes
///   when Coucou quits. Ours gets its own file. (From Louis-CFM/coucou#21.)
pub fn prepare_environment() {
    if std::env::var_os("GDK_BACKEND").is_none() {
        std::env::set_var("GDK_BACKEND", "x11");
    }
    if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }
    if std::env::var_os("APPIMAGE").is_some() && std::env::var_os("GST_REGISTRY").is_none() {
        let cache = xdg("XDG_CACHE_HOME", ".cache").join("coucou");
        if std::fs::create_dir_all(&cache).is_ok() {
            std::env::set_var("GST_REGISTRY", cache.join("gstreamer-registry.bin"));
        }
    }
}

/// localtime_r reads the zone from TZ / /etc/localtime, like `date` does.
pub fn local_time() -> LocalTime {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        libc::localtime_r(&now, &mut tm);
    }
    LocalTime {
        year: (tm.tm_year + 1900) as u32,
        month: (tm.tm_mon + 1) as u32,
        day: tm.tm_mday as u32,
        hour: tm.tm_hour as u32,
        minute: tm.tm_min as u32,
        second: tm.tm_sec as u32,
    }
}

// ── Processes ─────────────────────────────────────────────────────────────────

/// Spawns a helper detached from our stdio, without waiting for it.
pub fn spawn_quietly(cmd: &mut Command) -> bool {
    cmd.stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .is_ok()
}

pub fn open_url(url: &str) {
    spawn_quietly(Command::new("xdg-open").arg(url));
}

/// Opening a new window somewhere is not what "Open terminal" means on Linux:
/// it returns to the session itself, and only tmux makes that possible (see
/// `jump_to_session`). The front end hides the button otherwise.
pub fn open_project(_path: Option<&str>) -> bool {
    false
}

/// "Open terminal" on Linux: back to the tmux pane the session runs in.
///
/// Wayland lets no app raise another app's window, and GNOME Terminal & co.
/// offer no way to select one of their tabs from outside, so a session in a
/// plain terminal cannot be returned to — the island then only reports. Inside
/// tmux we can: its own server switches the attached client to the pane.
pub fn jump_to_session(tmux_socket: &str, tmux_pane: &str) -> bool {
    // Only a pane id (`%12`) and one of our own tmux sockets. Both come from our
    // relay, but nothing reaching a command line is taken on trust.
    let pane_ok = tmux_pane.len() > 1
        && tmux_pane.starts_with('%')
        && tmux_pane[1..].bytes().all(|b| b.is_ascii_digit());
    let socket_ok = Path::new(tmux_socket).is_absolute()
        && std::fs::symlink_metadata(tmux_socket)
            .map(|m| m.file_type().is_socket() && m.uid() == unsafe { libc::getuid() })
            .unwrap_or(false);
    if !pane_ok || !socket_ok {
        return false;
    }
    let Some(tmux) = find_on_path("tmux") else {
        log::line("tmux session, but no tmux on PATH");
        return false;
    };
    let run = |args: &[&str]| {
        Command::new(&tmux)
            .arg("-S")
            .arg(tmux_socket)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    };
    // The window and pane inside their session, then the client onto that
    // session. The last one fails harmlessly when the pane's session is already
    // the one on screen, or when nobody is attached.
    let found = run(&["select-window", "-t", tmux_pane]) && run(&["select-pane", "-t", tmux_pane]);
    if found {
        run(&["switch-client", "-t", tmux_pane]);
    }
    found
}

/// Our own `which`: the first executable file called `name` on $PATH.
pub fn find_on_path(name: &str) -> Option<PathBuf> {
    let dirs = std::env::var_os("PATH")?;
    std::env::split_paths(&dirs)
        .map(|dir| dir.join(name))
        .find(|p| {
            std::fs::metadata(p)
                .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        })
}

// ── Relay: Unix socket ────────────────────────────────────────────────────────
//
// The socket lives in a directory only we can enter, is mode 0600, and every
// connection is checked to come from our own uid; coucou-hook in turn checks
// the server is us (hook/src/unix.rs).

impl Relay for UnixStream {
    // Dropping the stream closes it; the hook reads until EOF or newline.
    fn finish(&mut self) {}
}

/// `$XDG_RUNTIME_DIR` is per-user and mode 0700 by specification; without one
/// we make `/tmp/coucou-<uid>` and insist it is ours and closed to everybody
/// else. Must match coucou-hook's `socket_path()` exactly.
fn socket_dir() -> Result<PathBuf, String> {
    if let Some(dir) = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute() && p.is_dir())
    {
        return Ok(dir);
    }
    let uid = unsafe { libc::getuid() };
    let dir = std::env::temp_dir().join(format!("coucou-{uid}"));
    let _ = std::fs::DirBuilder::new().mode(0o700).create(&dir);
    let meta = std::fs::symlink_metadata(&dir).map_err(|e| e.to_string())?;
    if !meta.is_dir() || meta.uid() != uid || meta.mode() & 0o077 != 0 {
        return Err(format!("{} is not a private directory of ours", dir.display()));
    }
    Ok(dir)
}

/// Serves the relay: one connection per hook event, handed to `pipe::handle`.
pub async fn serve_relay(app: AppHandle) {
    let path = match socket_dir() {
        Ok(dir) => dir.join("coucou.sock"),
        Err(err) => {
            log::line(format!("cannot open the relay socket: {err}"));
            return;
        }
    };
    // A socket file that still answers belongs to a running Coucou: do not
    // steal it. One that does not is left over from a crash.
    if path.exists() {
        if UnixStream::connect(&path).await.is_ok() {
            log::line(format!("{} is already served — not listening", path.display()));
            return;
        }
        let _ = std::fs::remove_file(&path);
    }
    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(err) => {
            log::line(format!("cannot open the relay socket {}: {err}", path.display()));
            return;
        }
    };
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    let me = unsafe { libc::getuid() };

    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(_) => {
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
        };
        // Only our own account gets to talk to the island.
        match stream.peer_cred() {
            Ok(cred) if cred.uid() == me => {}
            _ => continue,
        }
        let app = app.clone();
        tauri::async_runtime::spawn(async move { handle(app, stream).await });
    }
}

// ── Cursor ────────────────────────────────────────────────────────────────────

/// Global pointer position through GDK, in physical pixels.
pub fn cursor_physical(app: &AppHandle) -> Option<(f64, f64)> {
    let p = app.cursor_position().ok()?;
    Some((p.x, p.y))
}

/// GTK hands drags to whichever window is under the pointer once its input
/// shape takes the mouse, which happens as soon as the pointer is over the
/// island; there is no WebView2 drop target to fight. No need to watch the button.
pub fn left_button_down() -> bool {
    false
}

pub fn drag_may_start(_app: &AppHandle) {}

// ── Island window ─────────────────────────────────────────────────────────────

/// The window never takes focus from a click (GTK `accept-focus`), is marked as
/// a utility window so it stays out of Alt-Tab and the task bar, and shows on
/// every workspace.
pub fn make_non_activating(win: &WebviewWindow) {
    use gtk::prelude::{GtkWindowExt, WidgetExt};
    let _ = win.set_focusable(false);
    let _ = win.set_skip_taskbar(true);
    // Keeps GTK from pinning the size with min = max hints (see `set_input`);
    // without decorations nobody can resize it anyway.
    let _ = win.set_resizable(true);
    if let Ok(gtk_win) = win.gtk_window() {
        // Window managers only read the type hint when a window is mapped, and
        // the island is created visible: unmap it here, `setup` shows it again.
        gtk_win.hide();
        gtk_win.set_skip_pager_hint(true);
        gtk_win.set_type_hint(gtk::gdk::WindowTypeHint::Utility);
        gtk_win.stick();
    }
}

/// Temporarily allow activation so a text field inside the island can be typed in.
pub fn set_activating(win: &WebviewWindow, activating: bool) {
    let _ = win.set_focusable(activating);
}

/// Sets the window's input region.
///
/// A hidden island keeps its full-size window and takes the mouse on the wake
/// strip only. Shrinking the window to the strip, as on Windows, is what broke
/// it: a non-resizable GTK window gets its size from min = max WM hints, and
/// when the panel grew back Mutter/XWayland could apply the new height before
/// the new width, leaving a 240-px-wide window with the island cut off inside.
/// A window that never changes size has nothing to get half-way through, and
/// everything outside the strip is transparent and click-through, so a hidden
/// island still costs nothing.
///
/// Every change goes through this one main-thread queue, so they land in the
/// order they were made — mixing it with Tauri's own `set_ignore_cursor_events`
/// could let a stale "ignore" arrive after the strip and leave the hidden
/// island impossible to wake.
pub fn set_input(app: &AppHandle, input: Input) {
    use gtk::cairo::{RectangleInt, Region};
    use gtk::prelude::WidgetExt;
    let Some(win) = app.get_webview_window(WINDOW_LABEL) else { return };
    let _ = app.run_on_main_thread(move || {
        let Ok(gtk_win) = win.gtk_window() else { return };
        let rect = match input {
            Input::All => {
                gtk_win.input_shape_combine_region(None);
                return;
            }
            // What Tauri itself does for "ignore the cursor": a single pixel in
            // the corner, which on the island window is always transparent.
            Input::Nothing => RectangleInt::new(0, 0, 1, 1),
            Input::WakeStrip => RectangleInt::new(
                ((PANEL_W - STRIP_W) / 2.0).round() as i32,
                0,
                STRIP_W as i32,
                STRIP_H as i32,
            ),
        };
        if let Some(gdk_win) = gtk_win.window() {
            gdk_win.input_shape_combine_region(&Region::create_rectangle(&rect), 0, 0);
        }
    });
}
