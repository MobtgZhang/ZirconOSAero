//! 图形命令提交与电源管理占位（计划 G1–G3）。
//!
//! **G1** CP ring、PM4、IB、fence — 参考 `amdgpu` `gfx_v8_0`。
//! **G2** D0/D3hot、动态频率与系统休眠协调。
//! **G3** 用户态 API（WDDM / 自研 ioctl）单独立项。

const types = @import("types.zig");

pub fn registerGfxHandoffPath(family: types.AmdGpuFamily) void {
    _ = family;
}
