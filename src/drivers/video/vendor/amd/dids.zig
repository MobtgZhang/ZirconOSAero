//! AMD/ATI PCI Device ID — 与 Linux `drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c` pciid 表对齐的子集。
//! 维护：新增 DID 时请对照上游表；勿用宽区间覆盖 Polaris 与 GCN1–3 交界。

const types = @import("types.zig");

fn inList(comptime list: []const u16, id: u16) bool {
    inline for (list) |x| {
        if (id == x) return true;
    }
    return false;
}

/// amdgpu 表：Polaris12（含 RX550 Lexa 常见 0x699F）
pub const polaris12_dids = [_]u16{
    0x6980, 0x6981, 0x6985, 0x6986, 0x6987, 0x6995, 0x6997, 0x699F,
};

pub const polaris11_dids = [_]u16{
    0x67E0, 0x67E1, 0x67E3, 0x67E7, 0x67E8, 0x67E9, 0x67EB, 0x67EF, 0x67FF,
};

pub const polaris10_dids = [_]u16{
    0x67C0, 0x67C1, 0x67C2, 0x67C4, 0x67C7, 0x67C8, 0x67C9, 0x67CA,
    0x67CC, 0x67CF, 0x67D0, 0x67DF, 0x6FDF,
};

pub const tonga_dids = [_]u16{
    0x6920, 0x6921, 0x6928, 0x6929, 0x692B, 0x692F, 0x6930, 0x6938, 0x6939,
};

pub const fiji_dids = [_]u16{ 0x7300, 0x730F };

pub const topaz_dids = [_]u16{ 0x6900, 0x6901, 0x6902, 0x6903, 0x6907 };

pub const vegam_dids = [_]u16{ 0x694C, 0x694E, 0x694F };

pub const vega10_dids = [_]u16{
    0x6860, 0x6861, 0x6862, 0x6863, 0x6864, 0x6867, 0x6868, 0x6869,
    0x686A, 0x686B, 0x686C, 0x686D, 0x686E, 0x686F, 0x687F,
};

pub const vega12_dids = [_]u16{ 0x69A0, 0x69A1, 0x69A2, 0x69A3, 0x69AF };

pub const vega20_dids = [_]u16{
    0x66A0, 0x66A1, 0x66A2, 0x66A3, 0x66A4, 0x66A7, 0x66AF,
};

pub const navi10_dids = [_]u16{
    0x7310, 0x7312, 0x7318, 0x7319, 0x731A, 0x731B, 0x731E, 0x731F,
};

pub const navi12_dids = [_]u16{ 0x7360, 0x7362 };

pub const navi14_dids = [_]u16{ 0x7340, 0x7341, 0x7347, 0x734F };

pub const arcturus_dids = [_]u16{ 0x738C, 0x7388, 0x738E, 0x7390 };

/// 离散 GPU / APU 之外、由 amdgpu 驱动的 ASIC；须在 `legacy_ni_si` 宽区间之前匹配。
pub fn classifyAmdgpuDiscrete(device_id: u16) ?types.AmdGpuFamily {
    if (inList(&polaris12_dids, device_id)) return .polaris12;
    if (inList(&polaris11_dids, device_id)) return .polaris11;
    if (inList(&polaris10_dids, device_id)) return .polaris10;
    if (inList(&tonga_dids, device_id)) return .volcanic_islands;
    if (inList(&fiji_dids, device_id)) return .volcanic_islands;
    if (inList(&topaz_dids, device_id)) return .topaz;
    if (inList(&vegam_dids, device_id)) return .vegam;
    if (inList(&vega10_dids, device_id)) return .vega10;
    if (inList(&vega12_dids, device_id)) return .vega12;
    if (inList(&vega20_dids, device_id)) return .vega20;
    if (inList(&navi10_dids, device_id)) return .navi10;
    if (inList(&navi12_dids, device_id)) return .navi12;
    if (inList(&navi14_dids, device_id)) return .navi12;
    if (inList(&arcturus_dids, device_id)) return .arcturus;
    return null;
}

/// Southern Islands（Tahiti 等）— 与 Polaris 的 0x67C0+ 不重叠。
pub fn isGcnSouthernIslands(device_id: u16) bool {
    return device_id >= 0x6780 and device_id <= 0x679F;
}

pub const hawaii_dids = [_]u16{
    0x67A0, 0x67A1, 0x67A2, 0x67A8, 0x67A9, 0x67AA,
    0x67B0, 0x67B1, 0x67B8, 0x67B9, 0x67BA, 0x67BE,
};

pub fn isGcnHawaii(device_id: u16) bool {
    return inList(&hawaii_dids, device_id);
}

// --- Kaveri（Spectre / Spooky 等）— `family_detect` 区间 ---
pub const kaveri_range_first: u16 = 0x1304;
pub const kaveri_range_last: u16 = 0x131D;

// --- Kabini / Temash / Beema ---
pub const kabini_range_first: u16 = 0x9830;
pub const kabini_range_last: u16 = 0x983E;

// --- Mullins ---
pub const mullins_range_first: u16 = 0x9850;
pub const mullins_range_last: u16 = 0x9854;
