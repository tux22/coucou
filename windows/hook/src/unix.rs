//! The Linux side of the relay: a Unix socket in a directory only we can enter.
//!
//! `$XDG_RUNTIME_DIR` is created by the login manager for one user, mode 0700,
//! so nobody else can put a socket there. When a session has none we use
//! `/tmp/coucou-<uid>` and refuse it unless it is a real directory, ours, and
//! closed to everybody else. And once connected we still ask the kernel who is
//! on the other end before sending a single byte.

use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

/// Must match `socket_path()` in the app's pipe.rs exactly. Unlike the app we
/// never create anything: no directory means no Coucou, and we leave.
fn socket_path() -> Option<PathBuf> {
    let uid = unsafe { libc::getuid() };
    if let Some(dir) = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute() && p.is_dir())
    {
        return Some(dir.join("coucou.sock"));
    }
    let dir = std::env::temp_dir().join(format!("coucou-{uid}"));
    let meta = std::fs::symlink_metadata(&dir).ok()?;
    if !meta.is_dir() || meta.uid() != uid || meta.mode() & 0o077 != 0 {
        return None;
    }
    Some(dir.join("coucou.sock"))
}

/// Connects to Coucou. A missing socket (Coucou closed) or a refused connection
/// (Coucou crashed and left the file behind) fails immediately.
pub fn connect() -> Option<UnixStream> {
    let path = socket_path()?;
    let uid = unsafe { libc::getuid() };
    // Only a socket we own. symlink_metadata: a link planted in our place is not it.
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.file_type().is_socket() || meta.uid() != uid {
        return None;
    }
    let stream = UnixStream::connect(&path).ok()?;
    (peer_uid(&stream)? == uid).then_some(stream)
}

/// The uid of the process serving the socket, straight from the kernel.
#[cfg(target_os = "linux")]
fn peer_uid(stream: &UnixStream) -> Option<libc::uid_t> {
    use std::os::fd::AsRawFd;
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    (rc == 0).then_some(cred.uid)
}

/// Other Unixes: the socket's owner, checked above, is what we have.
#[cfg(not(target_os = "linux"))]
fn peer_uid(_stream: &UnixStream) -> Option<libc::uid_t> {
    Some(unsafe { libc::getuid() })
}
