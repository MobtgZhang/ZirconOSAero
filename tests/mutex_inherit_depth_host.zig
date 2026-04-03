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
