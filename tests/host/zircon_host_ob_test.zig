// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/host/zircon_host_ob_test.zig
// Purpose: 主机单元测试：`ob/object.zig` 等。由 `src/zircon_host_ob_test.zig` 符号链接指向本文件，使 Zig 模块根为 `src/`。
//
// This is an independent clean-room implementation.

const std = @import("std");
const ob = @import("ob/object.zig");

var g_section_cleanup_test_ptr: u64 = 0;
fn sectionCleanupTestHook(p: u64) void {
    g_section_cleanup_test_ptr = p;
}

test "handle table alloc increments ref_count and handle_count" {
    var hdr = ob.ObjectHeader{ .obj_type = .event, .ref_count = 1 };
    var table = ob.HandleTable.init(1);
    const h = table.allocHandle(@intFromPtr(&hdr), ob.GENERIC_READ, .event);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 2), hdr.refCount());
    try std.testing.expectEqual(@as(u32, 1), hdr.handleCount());
    try std.testing.expect(table.closeHandle(h.?));
    try std.testing.expectEqual(@as(u32, 1), hdr.refCount());
    try std.testing.expectEqual(@as(u32, 0), hdr.handleCount());
}

test "normalizeNtObjectPath strips NT prefixes" {
    try std.testing.expectEqualStrings("REGISTRY\\A", ob.normalizeNtObjectPath("\\??\\REGISTRY\\A"));
    try std.testing.expectEqualStrings("X", ob.normalizeNtObjectPath("\\DosDevices\\X"));
    try std.testing.expectEqualStrings("Vol", ob.normalizeNtObjectPath("\\\\?\\Vol"));
    try std.testing.expectEqualStrings("", ob.normalizeNtObjectPath(""));
    // 先剥 `\??\` 后，剩余串若无前导 `\` 则不再匹配 `\DosDevices\`（与当前实现一致，便于回归）
    try std.testing.expectEqualStrings("DosDevices\\Vol", ob.normalizeNtObjectPath("\\??\\DosDevices\\Vol"));
}

test "normalizeNtObjectPathResolveSymlinks matches normalizeNtObjectPath until P4-A2" {
    const s = "\\??\\REGISTRY\\A";
    try std.testing.expectEqualStrings(ob.normalizeNtObjectPath(s), ob.normalizeNtObjectPathResolveSymlinks(s));
}

test "normalizeNtObjectPathResolveSymlinks resolves one registered symbolic link" {
    ob.initNamespace();
    try std.testing.expect(ob.insertSymbolicLink("\\ZLink", "\\Devices\\ZDev", 0));
    try std.testing.expectEqualStrings("\\Devices\\ZDev", ob.normalizeNtObjectPathResolveSymlinks("\\ZLink"));
}

test "normalizeNtObjectPathResolveSymlinks follows up to 8 symlink hops" {
    // 不重复 `initNamespace()`：与其它用例共享同一主机测试进程内的命名空间表，仅用唯一路径前缀避免冲突。
    try std.testing.expect(ob.insertSymbolicLink("\\HopA", "\\HopB", 0));
    try std.testing.expect(ob.insertSymbolicLink("\\HopB", "\\HopC", 0));
    try std.testing.expect(ob.insertSymbolicLink("\\HopC", "\\Devices\\Final", 0));
    try std.testing.expectEqualStrings("\\Devices\\Final", ob.normalizeNtObjectPathResolveSymlinks("\\HopA"));
}

test "section last reference invokes cleanup hook" {
    const hooks = @import("ob/cleanup_hooks.zig");
    g_section_cleanup_test_ptr = 0;
    hooks.section_last_reference = sectionCleanupTestHook;
    defer hooks.section_last_reference = null;

    var hdr = ob.ObjectHeader{ .obj_type = .section, .ref_count = 0, .handle_count = 0 };
    var table = ob.HandleTable.init(1);
    const ptr: u64 = @intFromPtr(&hdr);
    const h = table.allocHandle(ptr, ob.GENERIC_ALL, .section) orelse return error.AllocHandle;
    try std.testing.expectEqual(@as(u32, 1), hdr.refCount());
    try std.testing.expectEqual(@as(u64, 0), g_section_cleanup_test_ptr);
    try std.testing.expect(table.closeHandle(h));
    try std.testing.expectEqual(ptr, g_section_cleanup_test_ptr);
}

test "handle table lookup and checkAccess" {
    var table = ob.HandleTable.init(99);
    var hdr = ob.ObjectHeader{ .obj_type = .mutex, .ref_count = 0, .handle_count = 0 };
    const ptr: u64 = @intFromPtr(&hdr);
    const h = table.allocHandle(ptr, ob.GENERIC_READ | ob.GENERIC_WRITE, .mutex) orelse return error.AllocFailed;
    const ent = table.lookupHandle(h) orelse return error.Lookup;
    try std.testing.expect(ent.obj_type == .mutex);
    try std.testing.expect(table.checkAccess(h, ob.GENERIC_READ));
    try std.testing.expect(!table.checkAccess(h, 0x0000_0001)); // P4-B3：未授予的访问位须失败
    try std.testing.expect(table.closeHandle(h));
}

test "handle table 10000x alloc close same object ref handle count and table count" {
    var hdr = ob.ObjectHeader{ .obj_type = .event, .ref_count = 1, .handle_count = 0 };
    var table = ob.HandleTable.init(1);
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        const h = table.allocHandle(@intFromPtr(&hdr), ob.GENERIC_READ, .event) orelse return error.AllocHandle;
        try std.testing.expectEqual(@as(u32, 2), hdr.refCount());
        try std.testing.expectEqual(@as(u32, 1), hdr.handleCount());
        try std.testing.expectEqual(@as(usize, 1), table.count);
        try std.testing.expect(table.closeHandle(h));
        try std.testing.expectEqual(@as(u32, 1), hdr.refCount());
        try std.testing.expectEqual(@as(u32, 0), hdr.handleCount());
        try std.testing.expectEqual(@as(usize, 0), table.count);
    }
}

test "duplicateHandle subset then close all restores ref and handle counts" {
    var hdr = ob.ObjectHeader{ .obj_type = .mutex, .ref_count = 1, .handle_count = 0 };
    var table = ob.HandleTable.init(7);
    const h0 = table.allocHandle(@intFromPtr(&hdr), ob.GENERIC_READ, .mutex) orelse return error.A0;
    var dupes: [16]ob.Handle = undefined;
    var d: usize = 0;
    while (d < dupes.len) : (d += 1) {
        dupes[d] = table.duplicateHandle(h0, 0) orelse return error.Dup;
    }
    try std.testing.expectEqual(@as(u32, @intCast(1 + dupes.len + 1)), hdr.refCount());
    try std.testing.expectEqual(@as(u32, @intCast(1 + dupes.len)), hdr.handleCount());
    try std.testing.expect(table.closeHandle(h0));
    for (dupes) |dh| try std.testing.expect(table.closeHandle(dh));
    try std.testing.expectEqual(@as(u32, 1), hdr.refCount());
    try std.testing.expectEqual(@as(u32, 0), hdr.handleCount());
    try std.testing.expectEqual(@as(usize, 0), table.count);
}

test "allocHandle rolls back ref and handle_count when handle table is full" {
    var hdr = ob.ObjectHeader{ .obj_type = .event, .ref_count = 1, .handle_count = 0 };
    var table = ob.HandleTable.init(1);
    var slots: [256]ob.ObjectHeader = undefined;
    var handles: [256]ob.Handle = undefined;
    var n: usize = 0;
    while (n < 256) : (n += 1) {
        slots[n] = .{ .obj_type = .event, .ref_count = 1, .handle_count = 0 };
        const hh = table.allocHandle(@intFromPtr(&slots[n]), ob.GENERIC_READ, .event) orelse return error.Fill;
        handles[n] = hh;
    }
    try std.testing.expectEqual(@as(usize, 256), table.count);
    const before_ref = hdr.refCount();
    const before_hc = hdr.handleCount();
    try std.testing.expect(table.allocHandle(@intFromPtr(&hdr), ob.GENERIC_READ, .event) == null);
    try std.testing.expectEqual(before_ref, hdr.refCount());
    try std.testing.expectEqual(before_hc, hdr.handleCount());
    var k: usize = 0;
    while (k < 256) : (k += 1) {
        try std.testing.expect(table.closeHandle(handles[k]));
    }
}

test "ObjectHeader wait list FIFO append and idempotent remove" {
    var hdr = ob.ObjectHeader{ .obj_type = .event };
    var e0: ob.WaitEntry = .{ .thread_index = 10, .hdr = &hdr };
    var e1: ob.WaitEntry = .{ .thread_index = 20, .hdr = &hdr };
    var e2: ob.WaitEntry = .{ .thread_index = 30, .hdr = &hdr };

    ob.waitListAppend(&hdr, &e0);
    ob.waitListAppend(&hdr, &e1);
    ob.waitListAppend(&hdr, &e2);
    try std.testing.expect(hdr.wait_list_head == &e0);
    try std.testing.expect(hdr.wait_list_tail == &e2);

    ob.waitListRemove(&e1);
    try std.testing.expect(e0.next == &e2);
    try std.testing.expect(e2.prev == &e0);
    ob.waitListRemove(&e1); // 幂等
    try std.testing.expect(e0.next == &e2);

    ob.waitListRemove(&e0);
    ob.waitListRemove(&e2);
    try std.testing.expect(hdr.wait_list_head == null);
    try std.testing.expect(hdr.wait_list_tail == null);
}
