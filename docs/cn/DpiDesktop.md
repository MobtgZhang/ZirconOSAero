# Aero 桌面与高 DPI 策略

## 目标

在 NT 6.1 风格下，对齐 Microsoft DWM 文档中的思路：**高 DPI 下可对旧应用做统一缩放回退**；本仓库采用分阶段实现。

## 当前阶段（v1）

- **逻辑坐标**：`theme.Layout`、`task栏`、窗口装饰等常量以 **参考分辨率下像素** 定义（如 1024×768 类布局）；未做系统级 DPI 感知注册表。
- **缩放策略**：由宿主在设置 `compositor.setScreenSize` / `renderer` 时按比例放大 `RenderOps` 中的矩形与字号，或在将来引入 `theme.Layout.scale_permille: u16`（千分比）统一乘算。
- **验收**：在 QEMU 固定分辨率下视觉正确；变更 `screen_width/height` 时任务栏贴底、Orb 与托盘相对位置保持（见 `theme.Layout`）。

## 后续

- 每监视器 DPI、非客户区缩放与 `GetDpiForWindow` 风格 API 映射到 `Win32Process` / user32（与 [DesktopManagerSpec.md](DesktopManagerSpec.md) 中的子系统表一致）。
