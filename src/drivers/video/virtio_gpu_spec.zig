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
}
