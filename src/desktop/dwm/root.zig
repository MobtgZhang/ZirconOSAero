//! Shared desktop DWM access layer.
//! Keeps both kernel compositor (`drivers/video/core/dwm.zig`) and host aero API reachable
//! through a stable desktop-level import path.

pub const core = @import("../../drivers/video/core/dwm.zig");
pub const aero_host = @import("../aero/src/dwm.zig");

pub fn isCoreEnabled() bool {
    return core.isEnabled();
}
