//! AMD/ATI 显示类 PCI Device ID — R7 及以下 APU / 老集显代表性枚举。
//! 完整列表请与 `pci.ids`、Linux `drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c`（pciid 表）、
//! `drivers/gpu/drm/radeon/radeon_drv.c` 交叉校验；同族相邻 ID 在 `family_detect.zig` 用区间补全。

// --- Stoney Ridge（常标 Radeon R4/R5/R7）---
pub const stoney_r7_example: u16 = 0x98E4;

// --- Carrizo / Bristol Ridge（R7 常见）：0x9870–0x987F（见 family_detect 区间）---

// --- Kaveri（Spectre / Spooky 等）---
pub const kaveri_range_first: u16 = 0x1304;
pub const kaveri_range_last: u16 = 0x131D;

// --- Kabini / Temash / Beema ---
pub const kabini_range_first: u16 = 0x9830;
pub const kabini_range_last: u16 = 0x983E;

// --- Mullins ---
pub const mullins_range_first: u16 = 0x9850;
pub const mullins_range_last: u16 = 0x9854;

// --- Trinity / Richland（示例）---
pub const trinity_example: u16 = 0x9900;

// --- Llano（示例）---
pub const llano_example: u16 = 0x9641;
