//! Shared icon mapping helpers for desktop stacks.

const aero_icon_ids = @import("../aero/src/icon_resource_ids.zig");
pub const kernel_icons = @import("../kernel/icons/root.zig");

pub fn peIdForIcon(id: kernel_icons.IconId) ?aero_icon_ids.PeIconId {
    return aero_icon_ids.peIdForLogicalIcon(@intFromEnum(id));
}

pub fn icoBasenameForIcon(id: kernel_icons.IconId) ?[]const u8 {
    const pe = peIdForIcon(id) orelse return null;
    return aero_icon_ids.icoBasenameForPeId(pe);
}
