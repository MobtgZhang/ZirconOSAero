//! 显示引擎分派（按代调用 gen9 / gen11 / 占位）

const types = @import("types.zig");
const gen9 = @import("gen9_display.zig");
const gen11 = @import("gen11_display.zig");
const klog = @import("../../../rtl/klog.zig");

/// `kms_experimental`：`-Dintel_kms_experimental=true` 时允许对显示 MMIO 做可选探测（默认关闭）。
pub fn initForGeneration(gen: types.IntelGpuGeneration, mmio_base: usize, kms_experimental: bool) types.DisplayInitResult {
    return switch (gen) {
        .gen9, .gen9_5 => gen9.initPipelineHandoffOnly(mmio_base, kms_experimental),
        .gen11 => gen11.initPipelineHandoffOnly(mmio_base, kms_experimental),
        .gen6, .gen7, .gen8 => blk: {
            if (klog.DEBUG_MODE) {
                klog.info("Intel display: Gen%u — legacy handoff only", .{@intFromEnum(gen)});
            }
            break :blk .handoff_only;
        },
        .unknown, .gen12_plus => blk: {
            if (klog.DEBUG_MODE) {
                klog.info("Intel display: generation unknown or Gen12+ — handoff only", .{});
            }
            break :blk .handoff_only;
        },
    };
}
