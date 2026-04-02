// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/storage/virtio_blk_pci.zig
// Purpose: VirtIO block PCI（1af4:1042）占位：枚举与 IRP 存储路径接线前的 **Planned** 钩子。
//
// Ref: Virtual I/O Device (VIRTIO) Version 1.2 — Block Device；PCI 设备 ID 见 virtio-spec。
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K5.2 / J2

const klog = @import("../../rtl/klog.zig");

/// VirtIO block PCI vendor/device（公开规范常量，非 Windows 专有实现）。
pub const pci_vendor_virtio: u16 = 0x1AF4;
pub const pci_device_virtio_blk: u16 = 0x1042;

var logged_once: bool = false;
var virtio_blk_pci_seen: bool = false;

pub fn isVirtioBlkPciPresent() bool {
    return virtio_blk_pci_seen;
}

/// 启动路径可调用：仅记录探测意图；MMIO/virtqueue 就绪后在此注册 `io` 设备与读盘 IRP。
pub fn noteVirtioBlkIfPresent(vendor_id: u16, device_id: u16) void {
    if (vendor_id != pci_vendor_virtio or device_id != pci_device_virtio_blk) return;
    virtio_blk_pci_seen = true;
    if (logged_once) return;
    logged_once = true;
    klog.info("VirtIO-Blk PCI (1af4:1042) detected — storage IRP path Planned (see NT61_CONTRACT_MATRIX)", .{});
}
