//! 龙芯 PCI 显示控制器 DID 白名单（Vendor 0x0014，class 0x03）。
//! 参考 pci.ids / Linux DRM（Etnaviv on Loongson）及社区资料；**实机请以 `lspci -nn` 为准**。
//!
//! | DID   | 常见关联（资料级，非龙芯官方承诺） |
//! |-------|--------------------------------------|
//! | 0x7a05 | LS2K1000 等 SoC 侧 Vivante |
//! | 0x7a15 | 7A1000 桥片集显 |
//! | 0x7a25 | 7A2000 / LG100 一代 |
//! | LG200 | 具体 DID 需在目标板上确认后补入 `supported_display_dids` |

/// 当前驱动阶段一仅对下列 DID 建立 MMIO 映射；其余 0014:03 设备忽略以免误触未知硬件。
pub const supported_display_dids: []const u16 = &.{
    0x7a05,
    0x7a15,
    0x7a25,
};

pub fn isSupportedDisplayDid(did: u16) bool {
    for (supported_display_dids) |d| {
        if (d == did) return true;
    }
    return false;
}
