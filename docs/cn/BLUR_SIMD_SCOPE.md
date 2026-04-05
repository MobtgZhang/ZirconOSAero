# Aero 盒式模糊与 SIMD 落点（D2）

x86_64 **内核**可执行文件在 `build.zig` 中禁用了 SSE/AVX 等 SIMD 特性（见项目规则：中断上下文不保存 SIMD 状态）。

因此 **全帧 `boxBlur` 向量化** 的合理落点为：

1. **用户态 Aero 合成库**（`src/desktop/aero/`）：可随宿主工具链开启 SIMD，与内核规则解耦。
2. **独立主机侧工具**（预渲染、离线模糊贴图）：不进入 freestanding 内核链接单元。

内核路径 `renderer_aero.zig` / `dwm.zig` 仍以标量循环为主，并受 `nt61_aero_defaults.KernelDwm.blur_*` 预算约束。
