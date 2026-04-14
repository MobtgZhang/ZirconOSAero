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

//! Shared desktop string gateway.
//! Gradually centralizes shell UI string access for both kernel desktop and aero host modules.

pub const shell_strings = @import("../kernel/strings/root.zig");
pub const shell_mui = @import("../kernel/strings/root.zig");

pub const LangId = shell_strings.LangId;

pub fn setActiveLang(id: LangId) void {
    shell_strings.setActiveLang(id);
}

pub fn startmenuLine(comptime field: []const u8) []const u8 {
    return shell_strings.startmenuLine(field);
}

pub fn explorerLine(comptime field: []const u8) []const u8 {
    return shell_strings.explorerLine(field);
}
