//! GOP / 固件帧缓冲 handoff；与 `amd/display_handoff.zig` 同级语义：默认不编程显示管道。

const types = @import("types.zig");
const chip_class = @import("chip_class.zig");
const klog = @import("../../../rtl/klog.zig");

pub fn initForFamily(family: types.NvidiaGpuFamily, mmio_virt: usize, kms_experimental: bool) types.DisplayInitResult {
    chip_class.logExperimentalMmioPeek(mmio_virt, kms_experimental);

    if (kms_experimental) {
        if (family == .unknown) {
            if (klog.DEBUG_MODE) klog.info("NVIDIA: experimental path skipped (family=unknown)", .{});
            return .handoff_only;
        }
        if (klog.DEBUG_MODE) {
            klog.info("NVIDIA: nvidia_kms_experimental — no engine writes; handoff only (family=%u)", .{
                @intFromEnum(family),
            });
        }
    }
    return .handoff_only;
}
