//! Intel iGPU driver — shared types

pub const IntelGpuGeneration = enum(u8) {
    unknown = 0,
    gen6 = 6,
    gen7 = 7,
    gen8 = 8,
    gen9 = 9,
    gen9_5 = 10,
    gen11 = 11,
    gen12_plus = 12,
};

pub const DisplayInitResult = enum(u8) {
    /// 仅使用固件/GOP 已建立的线性帧缓冲，不编程显示管道
    handoff_only = 0,
    /// 已尝试最小 KMS（未来）
    kms_partial = 1,
    failed = 2,
};
