//! 桌面帧缓冲解析：`main.zig` 唯一入口。顺序：龙芯（LoongArch 有效）→ Intel → AMD → GOP 原样。

const loongson_igpu = @import("loongson_igpu.zig");
const intel_igpu = @import("intel_igpu.zig");
const amd_igpu = @import("amd_igpu.zig");

pub const DesktopFb = intel_igpu.DesktopFb;

pub fn resolveDesktopFramebuffer(boot: DesktopFb) DesktopFb {
    const a = loongson_igpu.resolveDesktopFramebuffer(boot);
    const b = intel_igpu.resolveDesktopFramebuffer(a);
    return amd_igpu.resolveDesktopFramebuffer(b);
}
