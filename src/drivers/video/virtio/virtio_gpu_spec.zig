// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/virtio/virtio_gpu_spec.zig
// Purpose: VirtIO GPU device command types and wire layouts (host-testable constants).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://docs.oasis-open.org/virtio/virtio-v1.2-csd01/virtio-v1.2-csd01.html (GPU device)

const std = @import("std");

/// PCI vendor / device for VirtIO GPU (modern PCI transport).
pub const pci_vendor_virtio: u16 = 0x1AF4;
pub const pci_device_gpu: u16 = 0x1050;

/// Virtqueue indices (control queue 0, cursor queue 1 — typical for QEMU virtio-gpu-pci).
pub const vq_control: u16 = 0;
pub const vq_cursor: u16 = 1;

// Command types (le32 `type` field in virtio_gpu_ctrl_hdr). Values from VirtIO GPU device section.
pub const CMD_GET_DISPLAY_INFO: u32 = 0x0100;
pub const CMD_SET_SCANOUT: u32 = 0x0101;
pub const CMD_RESOURCE_FLUSH: u32 = 0x0102;
/// Cursor queue command（VirtIO GPU）；当前内核仅占位，供路线图与 QEMU 能力探测。
pub const CMD_UPDATE_CURSOR: u32 = 0x0300;
pub const CMD_RESOURCE_CREATE_2D: u32 = 0x0201;
pub const CMD_RESOURCE_UNREF: u32 = 0x0202;
pub const CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0203;
pub const CMD_RESOURCE_DETACH_BACKING: u32 = 0x0204;
pub const CMD_TRANSFER_TO_HOST_2D: u32 = 0x0205;
pub const CMD_TRANSFER_FROM_HOST_2D: u32 = 0x0206;

/// 3D / VirGL：与 Linux `uapi/linux/virtio_gpu.h` 中 `VIRTIO_GPU_CMD_CTX_CREATE` 数值一致（BSD 许可头文件，仅常量）。
pub const CMD_CTX_CREATE: u32 = 0x0200;

/// 光标队列：`VIRTIO_GPU_CMD_MOVE_CURSOR`（仅更新位置，不提交新位图）。
pub const CMD_MOVE_CURSOR: u32 = 0x0301;

/// 设备特性字 low 32 位中的 VirGL 位（`VIRTIO_GPU_F_VIRGL` = 0）。
pub const FEATURE_MASK_VIRGL: u32 = 1;

/// Response `type` values (device → driver), VirtIO GPU device section.
pub const RESP_OK_NODATA: u32 = 0x1100;
pub const RESP_OK_DISPLAY_INFO: u32 = 0x1101;

/// `format` for `CMD_RESOURCE_CREATE_2D` (VirtIO GPU device: `VIRTIO_GPU_FORMAT_*`).
pub const FORMAT_B8G8R8X8_UNORM: u32 = 1;

/// virtio_gpu_ctrl_hdr (device ↔ driver); all multi-byte fields are little-endian on the wire.
pub const CtrlHdr = extern struct {
    type: u32,
    flags: u32,
    fence_id: u64,
    ctx_id: u32,
    padding: u32,
};

comptime {
    std.debug.assert(@sizeOf(CtrlHdr) == 24);
    std.debug.assert(@offsetOf(CtrlHdr, "type") == 0);
}

test "virtio gpu ctrl header size" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(CtrlHdr));
}

test "command ids are distinct 2D path" {
    try std.testing.expect(CMD_RESOURCE_CREATE_2D != CMD_TRANSFER_TO_HOST_2D);
    try std.testing.expect(CMD_SET_SCANOUT != CMD_GET_DISPLAY_INFO);
    try std.testing.expect(RESP_OK_DISPLAY_INFO != CMD_GET_DISPLAY_INFO);
    try std.testing.expect(RESP_OK_NODATA != RESP_OK_DISPLAY_INFO);
}

test "set_scanout and flush wire sizes" {
    try std.testing.expectEqual(@as(usize, 48), set_scanout_req_len);
    try std.testing.expectEqual(set_scanout_req_len, resource_flush_req_len);
    try std.testing.expectEqual(@as(usize, 48), resourceAttachBackingReqLen(1));
    try std.testing.expectEqual(@as(usize, 64), resourceAttachBackingReqLen(2));
}

test "ctx create and move cursor wire sizes" {
    try std.testing.expectEqual(@as(usize, 96), ctx_create_req_len);
    try std.testing.expectEqual(@as(usize, 56), move_cursor_req_len);
}

/// Wire size of `virtio_gpu_resource_create_2d` (hdr + resource_id + format + width + height).
pub const resource_create_2d_req_len: usize = @sizeOf(CtrlHdr) + 16;

/// Wire size of `virtio_gpu_resource_attach_backing` with a single `virtio_gpu_mem_entry`.
pub const resource_attach_backing_1_req_len: usize = @sizeOf(CtrlHdr) + 8 + 16;

/// Wire size of `virtio_gpu_transfer_host_2d` (used for both TO_HOST and FROM_HOST commands).
pub const transfer_host_2d_req_len: usize = @sizeOf(CtrlHdr) + 16 + 8 + 8;

/// `virtio_gpu_set_scanout` / `virtio_gpu_resource_flush` (hdr + virtio_gpu_rect + two u32).
pub const set_scanout_req_len: usize = @sizeOf(CtrlHdr) + 16 + 4 + 4;
pub const resource_flush_req_len: usize = set_scanout_req_len;

/// Variable-size attach: hdr + resource_id + nr_entries + 16*nr_entries.
pub fn resourceAttachBackingReqLen(nr_entries: usize) usize {
    return @sizeOf(CtrlHdr) + 8 + 16 * nr_entries;
}

/// 与 [build.conf](build.conf) 注释表最大档 **3840×2160×32** 对齐：屏前缓冲按 4KiB 页拆成 `virtio_gpu_mem_entry` 的条数上界（最坏散列 GPA）。
pub const max_scanout_width: u32 = 3840;
pub const max_scanout_height: u32 = 2160;
pub const max_virtio_backing_mem_entries: usize = @intCast((@as(u64, @intCast(max_scanout_width)) *% @as(u64, @intCast(max_scanout_height)) *% 4 + 4095) / 4096);
/// 单条 `CMD_RESOURCE_ATTACH_BACKING` 控制请求体最大长度（`virtio_gpu_pci` / `framebuffer` 共用）。
pub const max_attach_backing_wire_bytes: usize = resourceAttachBackingReqLen(max_virtio_backing_mem_entries);

/// Fill `hdr.type` and zero the rest of the 24-byte control header.
pub fn writeCtrlHdrType(out: []u8, cmd_type: u32) void {
    std.debug.assert(out.len >= @sizeOf(CtrlHdr));
    std.mem.writeInt(u32, out[0..4], cmd_type, .little);
    @memset(out[4..@sizeOf(CtrlHdr)], 0);
}

/// Build `virtio_gpu_resource_create_2d` into `out` (must be `resource_create_2d_req_len` bytes).
pub fn writeResourceCreate2D(out: []u8, resource_id: u32, format: u32, width: u32, height: u32) void {
    std.debug.assert(out.len >= resource_create_2d_req_len);
    writeCtrlHdrType(out[0..24], CMD_RESOURCE_CREATE_2D);
    std.mem.writeInt(u32, out[24..][0..4], resource_id, .little);
    std.mem.writeInt(u32, out[28..][0..4], format, .little);
    std.mem.writeInt(u32, out[32..][0..4], width, .little);
    std.mem.writeInt(u32, out[36..][0..4], height, .little);
}

/// Build attach-backing with one guest memory chunk (physical `addr`, `length` bytes).
pub fn writeResourceAttachBacking1(out: []u8, resource_id: u32, addr: u64, length: u32) void {
    std.debug.assert(out.len >= resource_attach_backing_1_req_len);
    writeCtrlHdrType(out[0..24], CMD_RESOURCE_ATTACH_BACKING);
    std.mem.writeInt(u32, out[24..][0..4], resource_id, .little);
    std.mem.writeInt(u32, out[28..][0..4], 1, .little); // nr_entries
    std.mem.writeInt(u64, out[32..][0..8], addr, .little);
    std.mem.writeInt(u32, out[40..][0..4], length, .little);
    std.mem.writeInt(u32, out[44..][0..4], 0, .little); // padding
}

/// `cmd_type` must be `CMD_TRANSFER_TO_HOST_2D` or `CMD_TRANSFER_FROM_HOST_2D`.
pub fn writeTransferHost2D(
    out: []u8,
    cmd_type: u32,
    resource_id: u32,
    rect_x: u32,
    rect_y: u32,
    rect_w: u32,
    rect_h: u32,
    offset: u64,
) void {
    std.debug.assert(out.len >= transfer_host_2d_req_len);
    writeCtrlHdrType(out[0..24], cmd_type);
    std.mem.writeInt(u32, out[24..][0..4], rect_x, .little);
    std.mem.writeInt(u32, out[28..][0..4], rect_y, .little);
    std.mem.writeInt(u32, out[32..][0..4], rect_w, .little);
    std.mem.writeInt(u32, out[36..][0..4], rect_h, .little);
    std.mem.writeInt(u64, out[40..][0..8], offset, .little);
    std.mem.writeInt(u32, out[48..][0..4], resource_id, .little);
    std.mem.writeInt(u32, out[52..][0..4], 0, .little); // padding
}

/// `virtio_gpu_set_scanout`: full framebuffer resource on scanout `scanout_id` (usually 0).
pub fn writeSetScanout(out: []u8, scanout_id: u32, resource_id: u32, rx: u32, ry: u32, rw: u32, rh: u32) void {
    std.debug.assert(out.len >= set_scanout_req_len);
    writeCtrlHdrType(out[0..24], CMD_SET_SCANOUT);
    std.mem.writeInt(u32, out[24..][0..4], rx, .little);
    std.mem.writeInt(u32, out[28..][0..4], ry, .little);
    std.mem.writeInt(u32, out[32..][0..4], rw, .little);
    std.mem.writeInt(u32, out[36..][0..4], rh, .little);
    std.mem.writeInt(u32, out[40..][0..4], scanout_id, .little);
    std.mem.writeInt(u32, out[44..][0..4], resource_id, .little);
}

/// `virtio_gpu_resource_flush` after CPU (or DMA) updates to guest-backed resource pages.
pub fn writeResourceFlush(out: []u8, resource_id: u32, rx: u32, ry: u32, rw: u32, rh: u32) void {
    std.debug.assert(out.len >= resource_flush_req_len);
    writeCtrlHdrType(out[0..24], CMD_RESOURCE_FLUSH);
    std.mem.writeInt(u32, out[24..][0..4], rx, .little);
    std.mem.writeInt(u32, out[28..][0..4], ry, .little);
    std.mem.writeInt(u32, out[32..][0..4], rw, .little);
    std.mem.writeInt(u32, out[36..][0..4], rh, .little);
    std.mem.writeInt(u32, out[40..][0..4], resource_id, .little);
    std.mem.writeInt(u32, out[44..][0..4], 0, .little); // padding
}

pub const GpuMemEntry = struct {
    addr: u64,
    length: u32,
};

/// `virtio_gpu_ctx_create`：hdr + nlen + context_init + debug_name[64]（Linux uapi 布局）。
pub const ctx_create_req_len: usize = @sizeOf(CtrlHdr) + 4 + 4 + 64;

/// `virtio_gpu_update_cursor` / `MOVE_CURSOR` 共用布局（MOVE 时 resource/hot 字段设备可忽略）。
pub const move_cursor_req_len: usize = @sizeOf(CtrlHdr) + 16 + 4 + 4 + 4 + 4;

/// Build `VIRTIO_GPU_CMD_CTX_CREATE`：`ctx_id` 写入 hdr；`debug_name` 截断至 63 字节 + NUL。
pub fn writeCtxCreate(out: []u8, ctx_id: u32, debug_name: []const u8) void {
    std.debug.assert(out.len >= ctx_create_req_len);
    @memset(out[0..ctx_create_req_len], 0);
    std.mem.writeInt(u32, out[0..4], CMD_CTX_CREATE, .little);
    std.mem.writeInt(u32, out[16..20], ctx_id, .little);
    const ncopy = @min(debug_name.len, 63);
    std.mem.writeInt(u32, out[24..28], @intCast(ncopy), .little);
    std.mem.writeInt(u32, out[28..32], 0, .little); // context_init
    if (ncopy > 0) @memcpy(out[32 .. 32 + ncopy], debug_name[0..ncopy]);
}

/// `CMD_MOVE_CURSOR`：仅位置（scanout 0）；resource_id=0 表示不更换光标图像。
pub fn writeMoveCursor(out: []u8, scanout_id: u32, x: u32, y: u32) void {
    std.debug.assert(out.len >= move_cursor_req_len);
    @memset(out[0..move_cursor_req_len], 0);
    std.mem.writeInt(u32, out[0..4], CMD_MOVE_CURSOR, .little);
    std.mem.writeInt(u32, out[24..28], scanout_id, .little);
    std.mem.writeInt(u32, out[28..32], x, .little);
    std.mem.writeInt(u32, out[32..36], y, .little);
}

/// Multi-chunk attach (`nr_entries` virtio_gpu_mem_entry).
pub fn writeResourceAttachBackingN(out: []u8, resource_id: u32, entries: []const GpuMemEntry) void {
    const need = resourceAttachBackingReqLen(entries.len);
    std.debug.assert(out.len >= need);
    writeCtrlHdrType(out[0..24], CMD_RESOURCE_ATTACH_BACKING);
    std.mem.writeInt(u32, out[24..][0..4], resource_id, .little);
    std.mem.writeInt(u32, out[28..][0..4], @intCast(entries.len), .little);
    var o: usize = 32;
    for (entries) |e| {
        std.mem.writeInt(u64, out[o..][0..8], e.addr, .little);
        std.mem.writeInt(u32, out[o + 8 ..][0..4], e.length, .little);
        std.mem.writeInt(u32, out[o + 12 ..][0..4], 0, .little);
        o += 16;
    }
}

test "4k scanout backing entry and wire caps" {
    try std.testing.expectEqual(@as(usize, 8100), max_virtio_backing_mem_entries);
    try std.testing.expectEqual(@as(usize, 32 + 16 * 8100), max_attach_backing_wire_bytes);
}
