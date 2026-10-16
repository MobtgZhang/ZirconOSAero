//! Boot-stage screen console state shared by `klog` and the Boot Video Driver.
//!
//! The UEFI firmware owns the screen before `ExitBootServices`.  After the
//! kernel owns the framebuffer, BootVID displays kernel startup logs.  Once DWM
//! owns the desktop, the screen must never receive kernel log output again.

var active: bool = false;

pub fn setActive(enabled: bool) void {
    active = enabled;
}

pub fn isActive() bool {
    return active;
}
