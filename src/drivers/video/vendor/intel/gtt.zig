//! GGTT / stolen memory — 骨架实现（写入 PTE、完整 stolen 解析见 i915 `gtt.c`）

const pcie = @import("../../../bus/pcie.zig");
const klog = @import("../../../../rtl/klog.zig");

pub const StolenInfo = struct {
    base: u64 = 0,
    /// 为 0 表示未知（不再臆测固定 64MiB）
    size: u64 = 0,
    /// 仅表示「寄存器 0x5C 有可读非空值」，具体编码因平台而异
    valid: bool = false,
};

/// PCI 配置空间 0x5C：常作 stolen/graphics 相关 dword，定义随芯片组变化（见 PRM / i915）。
pub fn probeStolenHeuristic(loc: pcie.PciLoc) StolenInfo {
    const bdsm = pcie.readConfigDword(loc.bus, loc.dev, loc.func, 0x5C);
    klog.info("Intel GTT: cfg[0x5C] raw=0x%x (BDSM-like; size not inferred)", .{bdsm});
    if (bdsm == 0 or bdsm == 0xFFFFFFFF) return .{};
    const base = @as(u64, bdsm & 0xFFF00000);
    if (base == 0) {
        return .{ .valid = true, .base = 0, .size = 0 };
    }
    return .{
        .base = base,
        .size = 0,
        .valid = true,
    };
}

/// 预留：向 GGTT 写入映射（需 mmio 句柄与 unlocked 寄存器访问）
pub fn installFramebufferGttStub(mmio_phys: u64, fb_phys: u64, size: usize) bool {
    _ = mmio_phys;
    _ = fb_phys;
    _ = size;
    if (klog.DEBUG_MODE) {
        klog.info("Intel GTT: installFramebufferGttStub (no-op; handoff path)", .{});
    }
    return true;
}
