// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/zircon_host_ob_test.zig
// Purpose: 主机单元测试根文件 — 使 `ob/object.zig` 能通过 `../rtl/klog` 留在 `src/` 树内（Zig 0.15 模块边界）。
//
// This is an independent clean-room implementation.

const std = @import("std");
const ob = @import("ob/object.zig");

test "handle table alloc increments ref_count and handle_count" {
    var hdr = ob.ObjectHeader{ .obj_type = .event, .ref_count = 1 };
    var table = ob.HandleTable.init(1);
    const h = table.allocHandle(@intFromPtr(&hdr), ob.GENERIC_READ, .event);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 2), hdr.ref_count);
    try std.testing.expectEqual(@as(u32, 1), hdr.handle_count);
    try std.testing.expect(table.closeHandle(h.?));
    try std.testing.expectEqual(@as(u32, 1), hdr.ref_count);
    try std.testing.expectEqual(@as(u32, 0), hdr.handle_count);
}

test "handle table lookup and checkAccess" {
    var table = ob.HandleTable.init(99);
    var hdr = ob.ObjectHeader{ .obj_type = .mutex, .ref_count = 0, .handle_count = 0 };
    const ptr: u64 = @intFromPtr(&hdr);
    const h = table.allocHandle(ptr, ob.GENERIC_READ | ob.GENERIC_WRITE, .mutex) orelse return error.AllocFailed;
    const ent = table.lookupHandle(h) orelse return error.Lookup;
    try std.testing.expect(ent.obj_type == .mutex);
    try std.testing.expect(table.checkAccess(h, ob.GENERIC_READ));
    try std.testing.expect(table.closeHandle(h));
}
