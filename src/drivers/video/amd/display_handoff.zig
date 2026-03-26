//! AMD 显示管道 — GOP handoff；`amd_kms_experimental` 下仅登记与 PCI/MMIO 表面诊断，不写 GPU 寄存器。

const types = @import("types.zig");
const klog = @import("../../../rtl/klog.zig");
const mmio_probe = @import("mmio_probe.zig");
const display_dc_stub = @import("display_dc_stub.zig");
const gfx_pm_stub = @import("gfx_pm_stub.zig");

pub fn initForFamily(family: types.AmdGpuFamily, mmio_base: usize, kms_experimental: bool) types.DisplayInitResult {
    display_dc_stub.registerDcHandoffPath(family);
    gfx_pm_stub.registerGfxHandoffPath(family);
    mmio_probe.logHandoffDiagnostics(family, mmio_base, kms_experimental);

    if (kms_experimental) {
        if (family == .unknown) {
            if (klog.DEBUG_MODE) klog.info("AMD display: experimental KMS skipped (family=unknown)", .{});
            return .handoff_only;
        }
        if (klog.DEBUG_MODE) {
            klog.info("AMD display: kms_experimental set — no unsafe MMIO writes; handoff only (family=%u)", .{
                @intFromEnum(family),
            });
        }
    }
    return .handoff_only;
}
