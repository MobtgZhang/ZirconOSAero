//! NVIDIA 显示路径 — 与 Intel `DisplayInitResult` 对齐，便于 handoff / 未来 KMS 分阶段。

pub const DisplayInitResult = @import("../intel/types.zig").DisplayInitResult;

/// PCI DID 粗分代（启发式，非完整 nouveau pci 表；日志与实验路径用）
pub const NvidiaGpuFamily = enum(u8) {
    unknown = 0,
    legacy = 1,
    kepler = 2,
    maxwell = 3,
    pascal = 4,
    volta = 5,
    turing = 6,
    ampere = 7,
    ada_lovelace = 8,
};
