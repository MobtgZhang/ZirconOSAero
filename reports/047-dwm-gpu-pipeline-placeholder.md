# 问题 #47：DWM GPU 管线矩形与贴图绘制未实现

## 1. 问题编号

`47`

## 2. 问题位置

- 文件路径：`src/desktop/dwm/gpu_pipeline.zig`
- 函数/模块：`GPUCompositor.drawQuad`、`GPUCompositor.drawTexturedQuad`
- 行号或代码片段：原实现将全部参数标记为 `_`，只保留注释“这是占位符”。

## 3. 问题描述

`gpu_pipeline` 暴露了 DWM 的 D3D10/DXGI 绘制接口，但基础矩形绘制和贴图绘制均丢弃输入，导致该模块对桌面渲染没有实际贡献，也无法支撑 Aero 玻璃、图标和窗口合成以外的真实 2D 结果。

## 4. 复现路径

1. 检查 `GPUCompositor.drawQuad` 与 `drawTexturedQuad`。
2. 调用任意矩形或贴图绘制。
3. 观察交换链当前后缓冲内容没有变化。

## 5. 影响范围

- DWM GPU 管线状态统计为假成功；
- Aero 合成缺少可复用的基础 2D 绘制路径；
- 后续把 VirGL / VirtIO-GPU 2D 卸载接入 DWM 时缺少语义明确的中间层。

## 6. 严重程度

- High

## 7. 可能原因

早期实现只建立接口和统计结构，没有连接 `DwmSwapChain` 当前后缓冲与 `d3d10.texture` 数据池。

## 8. 权威参考依据

- Windows DWM 使用合成器合成窗口表面；基础矩形/贴图绘制必须写入渲染目标后才可呈现，参考 Microsoft Learn 的 DWM/D3D10 渲染目标与 DXGI 交换链模型。
- 本仓库实现依据 `src/desktop/dwm/dxgi/swap_chain.zig` 的双缓冲模型与 `src/desktop/dwm/d3d10/texture.zig` 的纹理数据池。
- 本条为源代码审查发现，未直接复制 Windows 版权代码。

## 9. 建议修复方案

`drawQuad` 写入当前后缓冲并执行 alpha 混合、坐标裁剪与越界忽略；`drawTexturedQuad` 从纹理池读取 RGBA 数据，按最近邻采样和 alpha 混合写入目标。`setViewport`、`setScissorRect` 传递给 D3D10 设备，`setBlendMode` 保留到管线状态。

## 10. 验证方法

1. 使用 Zig 0.18.0-dev 执行 `make build ARCH=x86_64`；
2. 执行 `make test ARCH=x86_64`；
3. 在 QEMU x86_64 中启动桌面，确认桌面、DWM 与 CMD 主循环未回归；
4. 后续接入真实 GPU 路径时，对比 CPU 后缓冲与 VirtIO scanout 的矩形结果。

## 11. 状态

- Fixed
