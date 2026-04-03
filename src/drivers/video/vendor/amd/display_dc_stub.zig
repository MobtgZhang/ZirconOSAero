//! Display Core / KMS 占位（计划 F1–F4）。
//!
//! **F1** Polaris 上 DC 依赖 VBIOS 表、SMU、时钟与 PHY；应对照 Linux `amdgpu_dm`、`dc/core`。
//! **F2** 最小模式集：单 CRTC + 单平面，或 GOP 分辨率验证路径。
//! **F3** 与 `hdmi.zig` 的 `syncFramebufferMode` / 连接器元数据衔接（见 `amd_igpu.resolveDesktopFramebuffer`）。
//! **F4** EDID / 热插拔在 KMS 就绪后接 DDC/AUX。

const types = @import("types.zig");

pub fn registerDcHandoffPath(family: types.AmdGpuFamily) void {
    _ = family;
}
