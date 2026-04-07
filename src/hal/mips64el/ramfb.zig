//! MIPS64EL QEMU ramfb via fw_cfg — same protocol as LoongArch, different base address.
//! QEMU MIPS Malta/loongson3-virt fw_cfg MMIO base varies by machine model.
//! This module provides the same interface shape as hal/loongarch64/ramfb.zig.

const klog = @import("../../rtl/klog.zig");

pub const RamfbInfo = struct {
    phys_addr: u64,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
};

var ramfb_configured: bool = false;
var current_info: RamfbInfo = .{
    .phys_addr = 0,
    .width = 0,
    .height = 0,
    .stride = 0,
    .format = 0,
};

// fw_cfg base for QEMU mips machines (platform-dependent, may need adjustment)
const FW_CFG_BASE: u64 = 0x1e020000;

pub fn setup(preferred_w: u32, preferred_h: u32) bool {
    _ = preferred_w;
    _ = preferred_h;
    // fw_cfg ramfb setup would go here — same DMA protocol as LoongArch.
    // Stub until QEMU MIPS virt machine fw_cfg is verified.
    klog.info("MIPS64EL ramfb: setup stub (fw_cfg base 0x{x})", .{FW_CFG_BASE});
    return false;
}

pub fn setupWithDims(phys: u64, w: u32, h: u32) bool {
    current_info = .{
        .phys_addr = phys,
        .width = w,
        .height = h,
        .stride = w * 4,
        .format = 0x34325258, // DRM_FORMAT_XRGB8888
    };
    ramfb_configured = true;
    return true;
}

pub fn isConfigured() bool {
    return ramfb_configured;
}

pub fn getInfo() ?RamfbInfo {
    if (!ramfb_configured) return null;
    return current_info;
}

pub fn pointRamfbToGuestPhys(phys: u64) void {
    current_info.phys_addr = phys;
}

pub fn runtimeReconfigure(w: u32, h: u32) bool {
    _ = w;
    _ = h;
    return false;
}

pub fn runtimeReconfigureAtGuestPhys(phys: u64, w: u32, h: u32) bool {
    _ = phys;
    _ = w;
    _ = h;
    return false;
}

pub fn guestReservedScanoutBytes() usize {
    if (!ramfb_configured) return 0;
    return @as(usize, current_info.stride) * @as(usize, current_info.height);
}
