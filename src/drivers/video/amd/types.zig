//! AMD 集成显卡 — 芯片族（与 Linux `amdgpu` CHIP_* / `radeon` asic_type 概念对齐，便于查寄存器头）。

/// 对应关系（实现注释 / 查 Linux 源码）：
/// - `stoney` — CHIP_STONEY，DCE11.3 量级，amdgpu
/// - `carrizo` — CHIP_CARRIZO（含多数 Bristol Ridge 显示路径），amdgpu
/// - `kaveri` — radeon Kaveri APU
/// - `kabini` / `mullins` — 低功耗 GCN APU，radeon
/// - `trinity_richland` / `llano` — VLIW / NI APU，radeon
/// - `rs880_igp` — 北桥集显等极老 ASIC
/// - `unknown` — 仍为 1002:03xx 但 DID 未收录；仅 GOP handoff，禁实验性 KMS 分派
pub const AmdGpuFamily = enum(u8) {
    unknown = 0,
    stoney = 1,
    carrizo = 2,
    kaveri = 3,
    kabini = 4,
    mullins = 5,
    trinity_richland = 6,
    llano = 7,
    rs880_igp = 8,
    /// 其它 Northern Islands / SI 等，寄存器与 amdgpu 新 ASIC 不同
    legacy_ni_si = 9,
};

pub const DisplayInitResult = @import("../intel/types.zig").DisplayInitResult;
