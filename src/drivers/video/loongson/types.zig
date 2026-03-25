pub const LoongsonGpuGeneration = enum(u8) {
    unknown = 0,
    vivante_ls2k1000 = 1,
    vivante_7a1000 = 2,
    lg100_7a2000 = 3,
    lg200 = 4,
};

pub const DisplayInitResult = enum(u8) {
    failed = 0,
    /// 仅与 UEFI GOP / ramfb handoff 对齐，不做模式集
    handoff_only = 1,
};
