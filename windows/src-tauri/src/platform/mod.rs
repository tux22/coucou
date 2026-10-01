// Everything that differs between operating systems, behind one set of names.
//
// The rest of the app calls `platform::…` and never touches Win32, GTK or a
// Unix API directly. Each OS file exposes the same items; the compiler picks
// one. (Same layout and names as the Linux proposal in Louis-CFM/coucou#21.)

use std::path::PathBuf;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use self::windows::*;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use self::linux::*;

/// Wall-clock time in the user's time zone, for log lines and backup names.
pub struct LocalTime {
    pub year: u32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
}

/// The user's home directory, where `.claude/settings.json` lives.
pub fn home_dir() -> PathBuf {
    std::env::var_os(HOME_VAR)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Which part of the island window takes the mouse.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Input {
    /// The whole window.
    All,
    /// Nothing: clicks go to whatever is underneath.
    Nothing,
    /// Only the wake strip at the top centre (a hidden island, where the
    /// window keeps its full size — see `SHRINKS_TO_STRIP`).
    WakeStrip,
}
