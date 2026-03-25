//! AMD 显示管道 — 首版仅 GOP handoff；`amd_kms_experimental` 下仅做安全只读探测占位。

const types = @import("types.zig");
const klog = @import("../../../rtl/klog.zig");

pub fn initForFamily(family: types.AmdGpuFamily, mmio_base: usize, kms_experimental: bool) types.DisplayInitResult {
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
    _ = mmio_base;
    return .handoff_only;
}
