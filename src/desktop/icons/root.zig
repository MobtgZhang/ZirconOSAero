// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

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
