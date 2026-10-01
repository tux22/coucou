<div align="center">

<img src="src-tauri/icons/128x128.png" width="96" alt="Coucou icon">

# Coucou for Windows

**Mochi doesn't get a notch on a PC — so it lives at the top of your screen instead.**

Approve Claude Code permissions, watch your session work, drop a file, chat with Claude, keep an eye on your services — without leaving what you're doing.

![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-0078D4?logo=windows)
![Tauri 2](https://img.shields.io/badge/Tauri-2-FFC131?logo=tauri&logoColor=black)
![Rust](https://img.shields.io/badge/Rust-backend-000?logo=rust)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

</div>

<img src="screenshots/greeting.png" width="640" alt="Mochi waving hello at launch">

---

## Install

The downloadable installer is **temporarily unavailable**. Microsoft Defender
wrongly flags the unsigned installer as malware (`Trojan:Win32/Wacatac.H!ml`, a
machine-learning false positive). A report is under review at Microsoft, and the
installer will be published again once it is cleared and code-signed.

Until then, [build it yourself](#build-it-yourself): it takes a few minutes and
installs for the current user only — no admin prompt.

## Using it

<img src="screenshots/compact.png" width="292" alt="The compact island, with the integration pills as mini Mochis">
<img src="screenshots/overview.png" width="640" alt="The overview: the focused integration on the left, the other pills on the right">
<img src="screenshots/approval.png" width="640" alt="A Claude Code permission request, with Deny and Allow">
<img src="screenshots/chat.png" width="640" alt="Chatting with Claude from the island">
<img src="screenshots/drop.png" width="640" alt="Mochi turned into a box, waiting for a file">

| What you do | What happens |
|---|---|
| Move the mouse to the very top-centre of the screen | Mochi peeks out |
| Click the small island | It opens |
| Click Mochi | It gets annoyed. Three times in a row and it goes dizzy |
| Rest the pointer on Mochi for two seconds | Hearts |
| Drag a file onto the island | Mochi turns into a box, swallows it, then offers to answer questions about it |
| `Esc`, or the `–` button | Closes the island — even with a permission request waiting: reopening it leads straight back to the card |
| Tray icon | Open, Settings…, Pause, Quit |

Everything else happens on its own: a Claude Code permission request opens the
island with **Deny / Allow**, a finished session shows what it did, and
your integrations sit in the coloured pills next to Mochi.

## Claude Code

<img src="screenshots/settings.png" width="562" alt="The settings window">

Open **Settings… → Claude Code → Install hooks…**. You get the exact diff of what
will change in `%USERPROFILE%\.claude\settings.json`, the path of the dated backup
that will be taken, and nothing is written until you click. Your own hooks are
never touched, and uninstalling removes only Coucou's entries.

The relay is a tiny executable, `coucou-hook.exe`, copied to
`%LOCALAPPDATA%\Coucou\bin\` at launch. It is given 300 ms to reach Coucou and
exits cleanly if the app is closed, slow or crashed — **a Claude Code session is
never blocked or slowed down by Coucou.** If nobody answers a permission request
in time, Coucou stays quiet and Claude Code asks in the terminal as usual.

It works from any terminal — Windows Terminal, PowerShell, VS Code, Git Bash.
The hooks are written in Claude Code's *exec form* (`"command"` is the relay's
path, `"args"` the event name), so no shell is involved: they work the same
whether Claude Code runs hooks through Git Bash or, on a PC without Git Bash,
through PowerShell, and spaces in the path are no problem. The relay links the
Visual C++ runtime statically, so it needs no Redistributable either.

## Chat and keys

**Settings… → Claude** takes your Anthropic API key. Keys live in the **Windows
Credential Manager**, never on disk and never in the interface — the island can
only ask whether a key exists. Same for every integration key.

No telemetry. The only network requests Coucou makes are to the services you
configure yourself.

## Build it yourself

You need [Rust](https://rustup.rs), [Node 20+](https://nodejs.org), and the
**MSVC build tools** (Visual Studio Build Tools with "Desktop development with
C++"). WebView2 ships with Windows 10/11.

```powershell
cd windows
npm install
npm run tauri dev      # live-reloading development build
npm run pack           # builds the installer and drops it in windows/release/
```

`npm run dev` alone serves the front end in an ordinary browser, which is enough
to work on the island's looks. It also serves `dev/upload-preview.html`, which
replays the whole file-drop choreography on a loop — the one part of the UI that
otherwise needs a real drag from Explorer to see. Neither page ships in the app.

`npm run pack` leaves two files in `windows/release/`, the same names the release
workflow publishes:

```
Coucou-Windows-X.Y.Z-setup.exe    the versioned installer
Coucou-Windows-setup.exe          the same file under the rolling name
```

Installing is optional — `target/release/coucou.exe` runs on its own. There is no
window in the taskbar and no console: the island at the top of the screen and the
Mochi in the notification area are the whole app, and Quit lives in its menu.

The 28 sounds are the macOS app's own files; they are never duplicated in this
folder. The path is declared once, in `SOUNDS_DIR` at the top of
`vite.config.ts` — when they move to `shared/sounds/`, change that one line.

The app icon and the tray icon are drawn in code, like Mochi itself:

```powershell
npm run icons          # regenerates src-tauri/icons from scripts/gen-icons.mjs
```

### Layout

```
windows/
  src/                 island front end (TypeScript, no framework)
    mochi/             Mochi and the launch greeting, in Canvas 2D
    island/            state machine, hooks, integrations
    views/             every island view
    settings/          the settings window
  src-tauri/           Rust backend: window, relay server, Claude API, pollers
    src/platform/      everything OS-specific: windows.rs, linux.rs
  hook/                coucou-hook(.exe), the Claude Code relay
  linux/               desktop entry, install script and README for the Linux tarball
  scripts/             icon generator, pack script, end-to-end tests
```

### End-to-end tests

`scripts/e2e/windows.ps1` and `scripts/e2e/linux.sh` start a release build,
send it Claude Code hook events through the real relay, click the island (the
approval queue, Allow/Deny, minimize and reopen) and check what Claude Code
would receive, saving screenshots (and GIFs on Linux) to `windows/e2e-out/`.
They point the app at throwaway folders, so your own settings are never
touched. Quit Coucou first.

```powershell
npx tauri build --no-bundle
pwsh scripts/e2e/windows.ps1
```

```bash
npx tauri build --no-bundle
scripts/e2e/linux.sh      # Xvfb, xdotool, ffmpeg, dbus-x11, and mutter or picom
```

The `E2E` workflow runs both on every pull request touching `windows/`.

### Log

`%LOCALAPPDATA%\Coucou\coucou.log` (Linux: `~/.local/share/coucou/coucou.log`)
— hook events, permission decisions, poller problems. It stays on your machine.

## What's different from the Mac version

- No notch, so the island lives at the top centre of the screen and retracts into
  the top edge instead of hiding in a notch.
- Permission approval works from **any** terminal; the Mac build only listens to
  VS Code sessions. Requests from several sessions queue up on the card
  ("1 of 2") and each gets its own answer; the island stays open while one waits,
  and one answered in the terminal leaves the card as soon as Claude Code runs
  or denies that call (Claude Code sends no event for the answer itself).
- Not in this version: sending a file by email, dragging Mochi onto a window to
  attach it as context, and jumping to a specific terminal window — "Open
  terminal" opens the working folder in VS Code when `code` is on your `PATH`.
- Cal.com shows the next bookings as a list rather than the Mac's calendar.

## Linux

The same app runs on Linux: this folder builds for both, and everything above
applies, with these differences.

### Install

Four packages, from the [latest Linux release](../../releases/tag/linux-latest):

| Package | For | How |
|---|---|---|
| `Coucou-Linux-amd64.deb` | Debian, Ubuntu, Mint, Pop!_OS… | `sudo apt install ./Coucou-Linux-amd64.deb` |
| `Coucou-Linux-x86_64.rpm` | Fedora, openSUSE, RHEL… | `sudo dnf install ./Coucou-Linux-x86_64.rpm` |
| `Coucou-Linux-x86_64.AppImage` | any distribution | `chmod +x Coucou-Linux-x86_64.AppImage` and run it |
| `Coucou-Linux-x86_64.tar.gz` | any distribution, no root | unpack, then `./install.sh` (installs in `~/.local`; `./install.sh --uninstall` removes it) |

The `.deb` and `.rpm` pull in what they need. For the AppImage and the tarball you need
WebKitGTK 4.1, GTK 3 and libayatana-appindicator3 (the tray icon), which most
desktops already have, plus the GStreamer "good" plugins for Mochi's sounds.

### What is different

- **X11.** The island has to place itself at the top of the screen, stay above
  everything and follow the cursor, and Wayland lets no ordinary app do any of
  that. Coucou therefore asks GTK for X11, which on a Wayland session means
  XWayland — present on GNOME, KDE and most others. Set `GDK_BACKEND` yourself
  to override. A compositor is needed for the transparent window (every modern
  desktop has one).
- **Keys** live in the **Secret Service** — GNOME Keyring, KWallet or KeePassXC —
  instead of the Windows Credential Manager. Still never on disk.
- **The relay** is `~/.local/share/coucou/bin/coucou-hook`, copied there at
  launch (an AppImage moves on every start, so `settings.json` must point at a
  stable copy). It talks to the app over a Unix socket in `$XDG_RUNTIME_DIR`,
  readable only by you, and both ends check with the kernel that the other one
  is your own account.
- **Paths:** preferences in `~/.config/coucou/`, log, relay and dropped files in
  `~/.local/share/coucou/`. `~/.claude/settings.json` gets the same backup,
  diff and explicit confirmation as everywhere else.
- **Start at login** adds a standard entry in `~/.config/autostart/`.
- **"Open terminal" needs tmux.** Wayland lets no app bring another app's
  window forward, and GNOME Terminal, Konsole & co. offer no way to select one
  of their tabs from outside, so a session in a plain terminal cannot be
  returned to: the island tells you it finished and that is all. Run Claude
  Code inside [tmux](https://github.com/tmux/tmux) and the button switches tmux
  back to the session's window and pane (bring the terminal forward yourself).
  The `.deb` and `.rpm` recommend tmux.
- A file dragged from the file manager has to be dropped on the island itself
  (on Windows the whole panel takes it).

### Build

You need [Rust](https://rustup.rs), [Node 20+](https://nodejs.org) and the
WebKitGTK development files. On Debian/Ubuntu:

```bash
sudo apt install libwebkit2gtk-4.1-dev libayatana-appindicator3-dev \
  librsvg2-dev libdbus-1-dev libxdo-dev patchelf file
cd windows
npm install
npm run tauri dev      # live-reloading development build
npm run pack           # .deb, .rpm, .AppImage and .tar.gz in windows/release/
```

(Fedora: `webkit2gtk4.1-devel libappindicator-gtk3-devel librsvg2-devel
dbus-devel libxdo-devel`; Arch: `webkit2gtk-4.1 libappindicator-gtk3 librsvg`.)

`npm run pack` leaves the same names the `linux-v*` release workflow publishes:

```
Coucou-Linux-X.Y.Z-amd64.deb
Coucou-Linux-X.Y.Z-x86_64.rpm
Coucou-Linux-X.Y.Z-x86_64.AppImage
Coucou-Linux-X.Y.Z-x86_64.tar.gz
```

plus copies under the version-less rolling names (the `.rpm` needs no
`rpmbuild`: Tauri writes it itself). Linux-only settings (bundle
targets, the relay resource, package dependencies) live in
`src-tauri/tauri.linux.conf.json`, which Tauri merges over `tauri.conf.json`.

### Where the OS-specific code lives

Everything that differs between Windows and Linux — paths, the relay
transport (named pipe / Unix socket), the window's click-through and focus
behaviour, opening URLs and projects — is in `src-tauri/src/platform/`:
`windows.rs` and `linux.rs` expose the same functions and constants, and the
rest of the app only calls `platform::…`. A change on one side must still
build on the other: `cargo check --target x86_64-pc-windows-gnu` works from
Linux.
