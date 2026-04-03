//! 龙芯显示：阶段一仅登记 handoff；KMS/扫描出见后续里程碑（对齐 Etnaviv/DRM 文档后再写 MMIO）。

const types = @import("types.zig");

pub fn initForGeneration(
    generation: types.LoongsonGpuGeneration,
    mmio_virt: usize,
    kms_experimental: bool,
) types.DisplayInitResult {
    _ = generation;
    _ = mmio_virt;
    _ = kms_experimental;
    return .handoff_only;
}
