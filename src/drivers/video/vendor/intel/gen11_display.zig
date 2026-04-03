//! Gen11（Ice Lake 等）— 显示寄存器块与 Gen9 有差异；当前与 handoff 路径共用探测骨架

const types = @import("types.zig");
const gen9 = @import("gen9_display.zig");
const klog = @import("../../../../rtl/klog.zig");

pub fn initPipelineHandoffOnly(mmio_base: usize, kms_experimental: bool) types.DisplayInitResult {
    const r = gen9.initPipelineHandoffOnly(mmio_base, kms_experimental);
    if (klog.DEBUG_MODE) {
        klog.info("Intel Gen11 display: using Gen11 init path (handoff)", .{});
    }
    return r;
}
