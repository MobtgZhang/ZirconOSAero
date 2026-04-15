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

//! SID (Security Identifier) definition
//! Shared between token.zig and security_descriptor.zig to break circular dependencies

pub const SID = struct {
    authority: u32 = 0,
    sub_authorities: [4]u32 = .{ 0, 0, 0, 0 },
    sub_count: u8 = 0,

    pub fn eql(self: SID, other: SID) bool {
        if (self.authority != other.authority) return false;
        if (self.sub_count != other.sub_count) return false;
        var i: u8 = 0;
        while (i < self.sub_count) : (i += 1) {
            if (self.sub_authorities[i] != other.sub_authorities[i]) return false;
        }
        return true;
    }
};

pub const SYSTEM_SID = SID{ .authority = 5, .sub_authorities = .{ 18, 0, 0, 0 }, .sub_count = 1 };
pub const ADMIN_SID = SID{ .authority = 5, .sub_authorities = .{ 32, 544, 0, 0 }, .sub_count = 2 };
pub const USER_SID = SID{ .authority = 5, .sub_authorities = .{ 21, 1, 0, 0 }, .sub_count = 2 };
pub const ANONYMOUS_SID = SID{ .authority = 5, .sub_authorities = .{ 7, 0, 0, 0 }, .sub_count = 1 };
