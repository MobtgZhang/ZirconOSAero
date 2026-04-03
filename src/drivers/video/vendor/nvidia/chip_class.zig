//! PCI DID → 粗代际（启发式，clean-room；不对照任何第三方驱动源码表）。
//! 后续迭代：按芯片族拆分 BAR、VRAM、显示引擎（见 `nvidia_gpu.zig` 顶部注释）。

const types = @import("types.zig");
const klog = @import("../../../rtl/klog.zig");

pub fn familyFromDeviceId(did: u16) types.NvidiaGpuFamily {
    const hi: u8 = @truncate(did >> 8);
    return switch (hi) {
        0x00...0x0F => .legacy,
        0x10...0x12 => .kepler,
        0x13...0x14 => .maxwell,
        0x15...0x17 => .pascal,
        0x18...0x1A => .volta,
        0x1B...0x1C => .turing,
        0x1D...0x1F => .ampere,
        0x20...0x28 => .ada_lovelace,
        else => .unknown,
    };
}

/// `nvidia_kms_experimental`：仅读 BAR0 首双字记录，**不写入**。部分平台可能仍不宜访问。
pub fn logExperimentalMmioPeek(mmio_virt: usize, kms_experimental: bool) void {
    if (!kms_experimental or mmio_virt == 0) return;
    const v = @as(*const volatile u32, @ptrFromInt(mmio_virt)).*;
    if (klog.DEBUG_MODE) klog.info("NVIDIA: experimental BAR0 peek @0 = 0x%x", .{v});
}
