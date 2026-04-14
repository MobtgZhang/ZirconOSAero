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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero — host-only model for `ke/scheduler.zig` mutex inheritance depth vs floor.
// Mirrors `beginMutexInheritance` / `updateMutexInheritFloor` / `endMutexInheritance`.

const std = @import("std");

const St = struct {
    floor: u8 = 0,
    depth: u32 = 0,

    fn begin(self: *St, pri: u8) void {
        self.depth +|= 1;
        self.floor = @max(self.floor, pri);
    }

    fn update(self: *St, pri: u8) void {
        self.floor = @max(self.floor, pri);
    }

    fn end(self: *St) void {
        if (self.depth == 0) return;
        self.depth -= 1;
        if (self.depth == 0) self.floor = 0;
    }
};

test "two parallel inherit edges: first end does not clear floor" {
    var t: St = .{};
    t.begin(10);
    t.begin(12);
    try std.testing.expectEqual(@as(u32, 2), t.depth);
    try std.testing.expectEqual(@as(u8, 12), t.floor);
    t.end();
    try std.testing.expectEqual(@as(u32, 1), t.depth);
    try std.testing.expectEqual(@as(u8, 12), t.floor);
    t.end();
    try std.testing.expectEqual(@as(u32, 0), t.depth);
    try std.testing.expectEqual(@as(u8, 0), t.floor);
}

test "update on same edge raises floor without depth bump" {
    var t: St = .{};
    t.begin(8);
    t.update(15);
    try std.testing.expectEqual(@as(u32, 1), t.depth);
    try std.testing.expectEqual(@as(u8, 15), t.floor);
    t.end();
    try std.testing.expectEqual(@as(u8, 0), t.floor);
}
