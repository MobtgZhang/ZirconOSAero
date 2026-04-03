//! AMD 显示路径产品与枚举策略（与计划 A 节对齐）。
//!
//! **A1 目标优先级（本仓库当前约定）**
//! 1. GOP / UEFI 已点亮的线性帧缓冲上桌面稳定（主路径）。
//! 2. 内核自主模式集（KMS / Display Core）为后续里程碑，默认不启用。
//! 3. 图形加速（CP ring、PM4）未纳入当前里程碑。
//!
//! **A2 设备矩阵**：真机 RX550（Polaris12）、APU+iGPU、纯 QEMU `-vga std`（无 1002:03xx）等需在发布说明中分别说明；CI 以 x86_64 默认构建为主。
//!
//! **A3 多 AMD 显示控制器**：PCI 扫描顺序不保证与「用户主屏」一致；在枚举到多块 1002 显示类设备时，按 `devicePriorityScore` 选取 primary（独显 Polaris/Vega 等优先于典型 APU）。

const pcie = @import("../../../bus/pcie.zig");
const types = @import("types.zig");

/// 数值越大越优先作为 `amd_igpu` primary（探测、MMIO 映射、HDMI 元数据）。
pub fn devicePriorityScore(family: types.AmdGpuFamily) u32 {
    return switch (family) {
        .polaris12 => 120,
        .polaris11, .polaris10 => 115,
        .vega20, .vega10, .vega12, .vegam => 112,
        .navi10, .navi12, .arcturus => 110,
        .volcanic_islands, .topaz => 105,
        .gcn_southern_islands, .gcn_hawaii => 88,
        .raven, .renoir => 55,
        .stoney, .carrizo, .kaveri, .kabini, .mullins => 50,
        .trinity_richland, .llano, .rs880_igp => 45,
        .legacy_ni_si => 40,
        .unknown => 10,
    };
}

fn scoreDevice(classify: *const fn (u16) types.AmdGpuFamily, device_id: u16) u32 {
    return devicePriorityScore(classify(device_id));
}

/// 在 `devs[0..len]` 中选 primary 下标；`classify` 须与 `family_detect.familyFromDeviceId` 一致。
pub fn pickPrimaryAmdDisplayIndex(devs: []const pcie.DisplayGfxPciInfo, classify: *const fn (u16) types.AmdGpuFamily) usize {
    if (devs.len <= 1) return 0;
    var best: usize = 0;
    var best_score = scoreDevice(classify, devs[0].device_id);
    var i: usize = 1;
    while (i < devs.len) : (i += 1) {
        const s = scoreDevice(classify, devs[i].device_id);
        if (s > best_score) {
            best = i;
            best_score = s;
        } else if (s == best_score) {
            // 同分时优先更高 PCI 总线号（常见独显在 root port 后，bus > 0）
            if (devs[i].loc.bus > devs[best].loc.bus) {
                best = i;
            }
        }
    }
    return best;
}
