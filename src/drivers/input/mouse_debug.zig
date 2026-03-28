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
/// `input_hub.pollAll` 调用次数（用于区分「合成慢」还是「输入轮询稀疏」）。
var input_hub_rounds: u32 = 0;
/// 上一轮桌面 tick 内 `mouse.popEvent` 次数（MOUSE_DEBUG 心跳打印）。
var events_popped_last_tick: u32 = 0;
/// `renderDesktopFrameEx` 路径分类（与 `DesktopRenderPathKind` 对应）。
/// 若 `full` 占比异常高，对照 `dwm.zig` 每帧模糊预算与 `handleMouseMove` 的 `needs_full_scene`（壳层打开时勿因光标形态强制全场景）。
var desktop_render_full_scene: u32 = 0;
var desktop_render_cursor_fast: u32 = 0;
var desktop_render_caption_partial: u32 = 0;
var desktop_render_drag_layer: u32 = 0;
var desktop_render_startmenu_partial: u32 = 0;

pub const DesktopRenderPathKind = enum {
    full,
    cursor_fast,
    caption_partial,
    /// 仅拖窗脏区 + `renderer_aero.renderDragFrame`（不把拖动态算进整场景 `scene_dirty`）
    drag_layer,
    /// `redrawStartMenuRegionOnly`（Harmony 预设下开始菜单悬停局部重绘）
    startmenu_partial,
};

pub fn noteInputHubRound() void {
    input_hub_rounds +%= 1;
}

pub fn setEventsPoppedLastTick(c: u32) void {
    events_popped_last_tick = c;
}

pub fn getInputHubRounds() u32 {
    return input_hub_rounds;
}

pub fn getEventsPoppedLastTick() u32 {
    return events_popped_last_tick;
}

/// 在 `renderDesktopFrameEx` 末尾调用。
pub fn noteDesktopRenderPath(kind: DesktopRenderPathKind) void {
    if (!enabled) return;
    switch (kind) {
        .full => desktop_render_full_scene +%= 1,
        .cursor_fast => desktop_render_cursor_fast +%= 1,
        .caption_partial => desktop_render_caption_partial +%= 1,
        .drag_layer => desktop_render_drag_layer +%= 1,
        .startmenu_partial => desktop_render_startmenu_partial +%= 1,
    }
}

pub fn getDesktopRenderFullCount() u32 {
    return desktop_render_full_scene;
}

pub fn getDesktopRenderCursorFastCount() u32 {
    return desktop_render_cursor_fast;
}

pub fn getDesktopRenderCaptionPartialCount() u32 {
    return desktop_render_caption_partial;
}

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
        klog.mouseDbg("desktop tick=%u pos=(%d,%d) virtio_pci=%u hub_rounds=%u pops_last=%u render_full=%u render_drag=%u render_cap=%u render_fast=%u", .{
            desktop_ticks,
            mx,
            my,
            @intFromBool(virtio_any),
            input_hub_rounds,
            events_popped_last_tick,
            desktop_render_full_scene,
            desktop_render_drag_layer,
            desktop_render_caption_partial,
            desktop_render_cursor_fast,
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
