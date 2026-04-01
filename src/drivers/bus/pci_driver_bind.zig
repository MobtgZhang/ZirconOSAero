// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/bus/pci_driver_bind.zig
// Purpose: PCI 配置空间类码 / 厂商 ID → 内核驱动占位绑定表（Detect → Bind 里程碑）；数据来自公开 PCI 类定义与本仓库枚举需求，不从 Windows INF 抄录。
//
// This is an independent clean-room implementation.
// Ref: PCI-SIG PCI Code and ID Assignment Specification (class/subclass); VirtIO 1.0 vendor 0x1AF4.
// Milestone: 计划 HW-1 / HW-2；与 [docs/cn/NT61_CONTRACT_MATRIX.md](../../../docs/cn/NT61_CONTRACT_MATRIX.md) §8、SOFTWARE_COMPOSITOR_WDDM（Virtio-GPU）一致。

const std = @import("std");

/// 内核内置驱动槽（占位枚举；AddDevice 路径见 `io.zig` 注册名对齐）。
pub const BoundDriver = enum(u8) {
    none = 0,
    /// USB3 xHCI 主机控制器（`src/drivers/usb/xhci.zig`）
    xhci = 1,
    /// USB2 EHCI 占位（`src/drivers/usb/ehci.zig`）
    ehci = 2,
    /// VirtIO GPU PCI（1af4:1050；规范路径里程碑）
    virtio_gpu = 3,
    /// VirtIO 网络（1af4:1000）
    virtio_net = 4,
    /// 显示类 0x03：由 vendor 再分派至 AMD/Intel/NVIDIA 探测链（非本表唯一键）
    display_class = 5,
};

/// 标准 PCI 类（基类，偏移 0x0B 高 8 位于 header type0）。
pub const ClassCode = struct {
    pub const serial_bus: u8 = 0x0C;
    pub const display: u8 = 0x03;
    pub const network: u8 = 0x02;
};

/// `class_code` = PCI 配置 class 字节；`subclass` / `prog_if` 与 `pcie.zig` 中 0x08 双字布局一致。
/// `prog_if`: programming interface byte (e.g. xHCI = 0x30).
pub fn lookupByClassProgIf(class_code: u8, subclass: u8, prog_if: u8) BoundDriver {
    if (class_code == ClassCode.serial_bus and subclass == 0x03) {
        if (prog_if == 0x30) return .xhci;
        if (prog_if == 0x20) return .ehci;
    }
    if (class_code == ClassCode.display) {
        return .display_class;
    }
    if (class_code == ClassCode.network) {
        // 具体机型由 `refineByVendorDevice`（如 VirtIO 1af4:1000）决定；非 VirtIO 网卡仍为 none。
        return .none;
    }
    return .none;
}

pub const VirtioVendor: u16 = 0x1AF4;
pub const VirtioGpuDevice: u16 = 0x1050;
pub const VirtioNetDevice: u16 = 0x1000;

/// 在类码绑定之后按厂商/设备细化（VirtIO 优先于泛型类匹配）。
pub fn refineByVendorDevice(vendor_id: u16, device_id: u16, class_fallback: BoundDriver) BoundDriver {
    if (vendor_id == VirtioVendor) {
        if (device_id == VirtioGpuDevice) return .virtio_gpu;
        if (device_id == VirtioNetDevice) return .virtio_net;
    }
    return class_fallback;
}

/// 单入口：PCI 配置空间偏移 **0x08** 双字（与 `pcie.zig` 一致）：rev、prog_if、subclass、class 自低字节至高字节。
pub fn lookupFromConfigClassWord(vendor_id: u16, device_id: u16, class_dword: u32) BoundDriver {
    const prog_if: u8 = @truncate((class_dword >> 8) & 0xFF);
    const subclass: u8 = @truncate((class_dword >> 16) & 0xFF);
    const class_code: u8 = @truncate((class_dword >> 24) & 0xFF);
    const coarse = lookupByClassProgIf(class_code, subclass, prog_if);
    return refineByVendorDevice(vendor_id, device_id, coarse);
}

test "pci bind xhci class 0c03 pi30" {
    const d = lookupByClassProgIf(0x0C, 0x03, 0x30);
    try std.testing.expect(d == .xhci);
}

test "pci bind virtio gpu by vendor device" {
    const d = refineByVendorDevice(VirtioVendor, VirtioGpuDevice, .display_class);
    try std.testing.expect(d == .virtio_gpu);
}

test "pci bind config word virtio net" {
    // PCI 0x08: rev=0, prog_if=0, sub=0, class=0x02 → LE dword 0x02000000
    const cw: u32 = 0x0200_0000;
    const d = lookupFromConfigClassWord(VirtioVendor, VirtioNetDevice, cw);
    try std.testing.expect(d == .virtio_net);
}

test "pci bind config dword xhci matches pcie layout" {
    const cw: u32 = 0x0C03_3000; // rev=0, PI=30, sub=03, class=0c
    const d = lookupFromConfigClassWord(0x8086, 0x1234, cw);
    try std.testing.expect(d == .xhci);
}
