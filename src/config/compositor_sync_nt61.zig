//! 阶段 C：用户态 compositor 与内核 DWM 像素层之间的 **LPC 载荷布局**（clean-room）。
//! 逻辑树（Z-order、脏区）**不得**依赖双端裸写共享缓冲；像素位图仍走既有重定向表面路径。
//! Ref: [SOFTWARE_COMPOSITOR_WDDM.md](../../docs/cn/SOFTWARE_COMPOSITOR_WDDM.md) 阶段 C 节。

const std = @import("std");

/// `KERNEL_DWM_NOTIFY` v1 魔数（ASCII `WDV1` 小端）。
pub const kernel_dwm_notify_v1_magic_le: u32 = 0x31564457;

pub const KernelDwmNotifyKind = enum(u8) {
    composition = 0,
    colorization = 1,
    nc_rendering = 2,
};

/// 写入 `ipc.MSG_DATA_SIZE` 缓冲的前缀；余字节清零。
pub fn encodeKernelDwmNotifyV1(out: *[64]u8, kind: KernelDwmNotifyKind, wp: u32, lp: i64) void {
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], kernel_dwm_notify_v1_magic_le, .little);
    out[4] = @intFromEnum(kind);
    std.mem.writeInt(u32, out[5..9], wp, .little);
    std.mem.writeInt(i64, out[9..17], lp, .little);
}

pub fn decodeKernelDwmNotifyV1(data: *const [64]u8) ?struct { kind: KernelDwmNotifyKind, wp: u32, lp: i64 } {
    const m = std.mem.readInt(u32, data[0..4], .little);
    if (m != kernel_dwm_notify_v1_magic_le) return null;
    const k = std.meta.intToEnum(KernelDwmNotifyKind, data[4]) catch return null;
    const wp = std.mem.readInt(u32, data[5..9], .little);
    const lp = std.mem.readInt(i64, data[9..17], .little);
    return .{ .kind = k, .wp = wp, .lp = lp };
}

/// `COMPOSITOR_TREE_SYNC` v1：世代号 + 至多 **13** 条表面 Z 快照（`ipc.MSG_DATA_SIZE=64`：`9 + 13×4 = 61`）。
/// 窗口多于 13 时 user32 **分片**发送多条消息，**同一代号**；内核按片合并补丁。
/// 内核 **只**据此重排所列 `surface_id` 的 `z_order`，不维护与用户态并行的第二真相。
pub const compositor_tree_sync_v1_magic_le: u32 = 0x31545343; // CST1

pub const compositor_tree_sync_v1_max_entries: u8 = 13;

pub const TreeSurfaceEntryV1 = struct {
    surface_id: u16,
    z_order: i16,
};

pub fn encodeCompositorTreeSyncV1(
    out: *[64]u8,
    generation: u32,
    entries: []const TreeSurfaceEntryV1,
) void {
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], compositor_tree_sync_v1_magic_le, .little);
    std.mem.writeInt(u32, out[4..8], generation, .little);
    const n = @min(entries.len, @as(usize, compositor_tree_sync_v1_max_entries));
    out[8] = @intCast(n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const off = 9 + i * 4;
        std.mem.writeInt(u16, out[off..][0..2], entries[i].surface_id, .little);
        std.mem.writeInt(i16, out[off + 2 ..][0..2], entries[i].z_order, .little);
    }
}

pub fn decodeCompositorTreeSyncV1(data: *const [64]u8) ?struct { generation: u32, entries: [compositor_tree_sync_v1_max_entries]TreeSurfaceEntryV1, count: u8 } {
    const m = std.mem.readInt(u32, data[0..4], .little);
    if (m != compositor_tree_sync_v1_magic_le) return null;
    const gen = std.mem.readInt(u32, data[4..8], .little);
    const n = data[8];
    if (n > compositor_tree_sync_v1_max_entries) return null;
    var entries: [compositor_tree_sync_v1_max_entries]TreeSurfaceEntryV1 = undefined;
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const off = 9 + @as(usize, i) * 4;
        entries[i] = .{
            .surface_id = std.mem.readInt(u16, data[off..][0..2], .little),
            .z_order = std.mem.readInt(i16, data[off + 2 ..][0..2], .little),
        };
    }
    return .{ .generation = gen, .entries = entries, .count = n };
}

test "kernel dwm notify round-trip" {
    var buf: [64]u8 = undefined;
    encodeKernelDwmNotifyV1(&buf, .composition, 1, 0);
    const d = decodeKernelDwmNotifyV1(&buf).?;
    try std.testing.expect(d.kind == .composition);
    try std.testing.expectEqual(@as(u32, 1), d.wp);
    try std.testing.expectEqual(@as(i64, 0), d.lp);
}

test "compositor tree sync round-trip" {
    var buf: [64]u8 = undefined;
    const ent = [_]TreeSurfaceEntryV1{
        .{ .surface_id = 2, .z_order = 10 },
        .{ .surface_id = 5, .z_order = 20 },
    };
    encodeCompositorTreeSyncV1(&buf, 0xAABBCCDD, &ent);
    const d = decodeCompositorTreeSyncV1(&buf).?;
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), d.generation);
    try std.testing.expectEqual(@as(u8, 2), d.count);
    try std.testing.expectEqual(@as(u16, 2), d.entries[0].surface_id);
    try std.testing.expectEqual(@as(i16, 10), d.entries[0].z_order);
}

test "compositor tree sync v1 max 13 entries round-trip" {
    var buf: [64]u8 = undefined;
    var ent: [compositor_tree_sync_v1_max_entries]TreeSurfaceEntryV1 = undefined;
    var i: usize = 0;
    while (i < compositor_tree_sync_v1_max_entries) : (i += 1) {
        ent[i] = .{ .surface_id = @intCast(i), .z_order = @intCast(i * 7) };
    }
    encodeCompositorTreeSyncV1(&buf, 0x01020304, &ent);
    const d = decodeCompositorTreeSyncV1(&buf).?;
    try std.testing.expectEqual(@as(u8, compositor_tree_sync_v1_max_entries), d.count);
    try std.testing.expectEqual(@as(u16, 12), d.entries[12].surface_id);
    try std.testing.expectEqual(@as(i16, 12 * 7), d.entries[12].z_order);
}
