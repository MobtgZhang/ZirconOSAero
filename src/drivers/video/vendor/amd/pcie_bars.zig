//! AMD 显示控制器 PCI BAR 分类（计划 B1–B2）：区分寄存器 MMIO 与 VRAM aperture。
//! 参考 Linux `amdgpu_device.c` 典型布局：BAR0 非预取小窗口 = 寄存器；大预取 BAR = VRAM。

const klog = @import("../../../../rtl/klog.zig");
const pcie = @import("../../../bus/pcie.zig");

pub const ClassifiedBars = struct {
    /// 编程用 MMIO（非预取、通常为首个较小 memory BAR）
    reg: ?pcie.PciBarResource,
    /// 显存窗口（预取、通常远大于寄存器块）
    vram: ?pcie.PciBarResource,
};

fn barBetterVram(candidate: pcie.PciBarResource, current: ?pcie.PciBarResource) bool {
    if (current == null) return true;
    return candidate.size > current.?.size;
}

fn barBetterReg(candidate: pcie.PciBarResource, current: ?pcie.PciBarResource) bool {
    if (current == null) return true;
    return candidate.size < current.?.size;
}

/// 对典型 amdgpu 独显启发式分类；单 BAR 集显路径上 `vram` 可能为空。
pub fn classifyAmdDisplayBars(dev: *const pcie.DisplayGfxPciInfo) ClassifiedBars {
    var out = ClassifiedBars{ .reg = null, .vram = null };
    for (dev.bars) |bar| {
        if (bar.is_io or bar.size == 0 or bar.base == 0) continue;
        if (bar.prefetchable) {
            if (barBetterVram(bar, out.vram)) out.vram = bar;
        } else {
            if (barBetterReg(bar, out.reg)) out.reg = bar;
        }
    }
    return out;
}

/// 寄存器 MMIO 物理基址：优先非预取最小 BAR，否则退回首个有效 memory BAR（与 `firstMmioBar` 行为接近）。
pub fn registerMmioBar(dev: *const pcie.DisplayGfxPciInfo) ?pcie.PciBarResource {
    const c = classifyAmdDisplayBars(dev);
    if (c.reg) |r| return r;
    return pcie.firstMmioBar(dev);
}

pub fn logBarSummary(dev: *const pcie.DisplayGfxPciInfo, classified: ClassifiedBars) void {
    if (!klog.DEBUG_MODE) return;
    if (classified.reg) |r| {
        klog.info("AMD PCI BAR: MMIO reg phys=0x%x size=0x%x", .{ r.base, r.size });
    } else {
        klog.info("AMD PCI BAR: MMIO reg none", .{});
    }
    if (classified.vram) |v| {
        klog.info("AMD PCI BAR: VRAM aperture phys=0x%x size=0x%x prefetch=%u", .{
            v.base,
            v.size,
            @intFromBool(v.prefetchable),
        });
    } else {
        klog.info("AMD PCI BAR: VRAM aperture none (typical iGPU)", .{});
    }
    _ = dev;
}
