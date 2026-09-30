// Local wall-clock time for log lines and backup names, without pulling in a
// date crate: the OS already knows the time zone.

/// Year, month, day, hour, minute, second in local time.
pub struct LocalTime {
    pub year: u16,
    pub month: u16,
    pub day: u16,
    pub hour: u16,
    pub minute: u16,
    pub second: u16,
}

#[cfg(windows)]
pub fn now() -> LocalTime {
    let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    LocalTime {
        year: t.wYear,
        month: t.wMonth,
        day: t.wDay,
        hour: t.wHour,
        minute: t.wMinute,
        second: t.wSecond,
    }
}

#[cfg(unix)]
pub fn now() -> LocalTime {
    // localtime_r reads the zone from TZ / /etc/localtime, like `date` does.
    let secs = unsafe { libc::time(std::ptr::null_mut()) };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&secs, &mut tm) };
    LocalTime {
        year: (tm.tm_year + 1900) as u16,
        month: (tm.tm_mon + 1) as u16,
        day: tm.tm_mday as u16,
        hour: tm.tm_hour as u16,
        minute: tm.tm_min as u16,
        second: tm.tm_sec as u16,
    }
}
