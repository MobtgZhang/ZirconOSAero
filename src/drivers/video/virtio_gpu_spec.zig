// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/virtio_gpu_spec.zig
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
pub const CMD_RESOURCE_CREATE_2D: u32 = 0x0201;
pub const CMD_RESOURCE_UNREF: u32 = 0x0202;
pub const CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0203;
pub const CMD_RESOURCE_DETACH_BACKING: u32 = 0x0204;
pub const CMD_TRANSFER_TO_HOST_2D: u32 = 0x0205;
pub const CMD_TRANSFER_FROM_HOST_2D: u32 = 0x0206;

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

/// Wire size of `virtio_gpu_resource_create_2d` (hdr + resource_id + format + width + height).
pub const resource_create_2d_req_len: usize = @sizeOf(CtrlHdr) + 16;

/// Wire size of `virtio_gpu_resource_attach_backing` with a single `virtio_gpu_mem_entry`.
pub const resource_attach_backing_1_req_len: usize = @sizeOf(CtrlHdr) + 8 + 16;

/// Wire size of `virtio_gpu_transfer_host_2d` (used for both TO_HOST and FROM_HOST commands).
pub const transfer_host_2d_req_len: usize = @sizeOf(CtrlHdr) + 16 + 8 + 8;

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
