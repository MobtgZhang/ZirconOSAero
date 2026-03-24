//! 可选编译（`-Dmouse_debug=true`）：串口/控制台输出指针坐标与 VirtIO 队列快照，底栏叠加 `ptr x,y`。
//! 用于判断「主循环在跑 / VirtIO used 环是否在前进 / deliver 是否被调用」。
//! 与 `agent_ndjson.zig` 中 H1–H7 对照；`noteVirtioSyncDeliver` 统计 `syncDeliver` 次数（确认 SYN/REL 是否送达 mouse 层）。

const klog = @import("../../rtl/klog.zig");

pub const enabled: bool = @import("build_options").mouse_debug;

var virtio_poll_ctr: [2]u32 = .{ 0, 0 };
var desktop_ticks: u32 = 0;
var last_hb_x: i32 = 0x7fff_fff0;
var last_hb_y: i32 = 0x7fff_fff0;
var virtio_sync_deliver_count: u32 = 0;

/// VirtIO-Input 在 `syncDeliver` 路径每递交一次鼠标包 +1（仅 mouse_debug）。
pub fn noteVirtioSyncDeliver() void {
    if (!enabled) return;
    virtio_sync_deliver_count +%= 1;
    if (virtio_sync_deliver_count <= 64 or virtio_sync_deliver_count % 256 == 0) {
        klog.mouseDbg("virtio syncDeliver total=%u", .{virtio_sync_deliver_count});
    }
}

pub fn snapshotVirtio(inst_i: u8, active: bool, used_idx: u16, last_used: u16) void {
    if (!enabled) return;
    const ii: usize = @intCast(@min(inst_i, virtio_poll_ctr.len - 1));
    virtio_poll_ctr[ii] +%= 1;
    if (virtio_poll_ctr[ii] % 256 != 0) return;
    klog.mouseDbg("virtio inst=%u active=%u used.idx=%u last_used=%u polls=%u", .{
        inst_i,
        @intFromBool(active),
        used_idx,
        last_used,
        virtio_poll_ctr[ii],
    });
}

pub fn desktopHeartbeat(mx: i32, my: i32, virtio_any: bool) void {
    if (!enabled) return;
    desktop_ticks +%= 1;
    const moved = (mx != last_hb_x or my != last_hb_y);
    if (moved or (desktop_ticks % 48 == 0)) {
        last_hb_x = mx;
        last_hb_y = my;
        klog.mouseDbg("desktop tick=%u pos=(%d,%d) virtio_pci=%u", .{
            desktop_ticks,
            mx,
            my,
            @intFromBool(virtio_any),
        });
    }
}

pub fn traceAfterDeliver(x: i32, y: i32, raw_dx: i16, raw_dy: i16, buttons: u8) void {
    if (!enabled) return;
    klog.mouseDbg("deliver pos=(%d,%d) raw_d=(%d,%d) btn=0x%x", .{
        x,
        y,
        raw_dx,
        raw_dy,
        buttons,
    });
}
