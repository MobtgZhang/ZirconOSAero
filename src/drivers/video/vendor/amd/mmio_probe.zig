//! 实验性探测（计划 D1）：默认 **不写 MMIO**；仅配合 `amd_kms_experimental` 做表面登记。
//! 真寄存器只读需按 ASIC 填偏移表；盲目读可能挂死部分平台。

const klog = @import("../../../../rtl/klog.zig");
const types = @import("types.zig");

pub fn logHandoffDiagnostics(family: types.AmdGpuFamily, mmio_virt: usize, kms_experimental: bool) void {
    if (!kms_experimental) return;
    if (family == .unknown) return;
    if (klog.DEBUG_MODE) {
        klog.info("AMD MMIO probe: family=%u mmio_virt=0x%x (handoff-only; no MMIO reads)", .{
            @intFromEnum(family),
            mmio_virt,
        });
    }
}
