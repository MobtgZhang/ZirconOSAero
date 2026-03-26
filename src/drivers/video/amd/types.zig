//! AMD 显示控制器 — 芯片族（与 Linux `amdgpu` CHIP_* 概念对齐，便于查寄存器头）。

/// 对应关系（实现注释 / 查 Linux 源码）：
/// - `stoney` — CHIP_STONEY，DCE11.3 量级，amdgpu
/// - `carrizo` — CHIP_CARRIZO（含多数 Bristol Ridge 显示路径），amdgpu
/// - `kaveri` — radeon Kaveri APU
/// - `kabini` / `mullins` — 低功耗 GCN APU，radeon
/// - `trinity_richland` / `llano` — VLIW / NI APU，radeon
/// - `rs880_igp` — 北桥集显等极老 ASIC
/// - `polaris10` / `polaris11` / `polaris12` — GCN4 离散（RX550 = polaris12 / Lexa）
/// - `volcanic_islands` — Tonga / Fiji
/// - `topaz` — 低端 GCN
/// - `vegam` / `vega10` / `vega12` / `vega20` — Vega 系
/// - `gcn_southern_islands` / `gcn_hawaii` — GCN1–2 离散（KMS 未实现时仍为 GOP handoff）
/// - `raven` / `renoir` — Ryzen APU
/// - `navi10` / `navi12` — RDNA1 子集（含 Navi14 DID 映射到 navi12 桶）
/// - `arcturus` — CDNA 类（枚举用途）
/// - `legacy_ni_si` — Northern Islands / 老 SI 等与 amdgpu 新 ASIC 寄存器不兼容的桶
/// - `unknown` — DID 未收录；仅 GOP handoff，禁实验性 KMS 分派
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
    legacy_ni_si = 9,
    polaris12 = 10,
    polaris11 = 11,
    polaris10 = 12,
    volcanic_islands = 13,
    topaz = 14,
    vegam = 15,
    vega10 = 16,
    vega12 = 17,
    vega20 = 18,
    gcn_southern_islands = 19,
    gcn_hawaii = 20,
    raven = 21,
    renoir = 22,
    navi10 = 23,
    navi12 = 24,
    arcturus = 25,
};

pub const DisplayInitResult = @import("../intel/types.zig").DisplayInitResult;
