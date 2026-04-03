# Aero 桌面与高 DPI 策略

## 目标

在 NT 6.1 风格下，对齐 Microsoft DWM 文档中的思路：**高 DPI 下可对旧应用做统一缩放回退**；本仓库采用分阶段实现。

## 当前阶段（v1）

- **逻辑坐标**：`theme.Layout`、`task栏`、窗口装饰等常量以 **参考分辨率下像素** 定义（如 1024×768 类布局）；未做系统级 DPI 感知注册表。
- **缩放策略**：由宿主在设置 `compositor.setScreenSize` / `renderer` 时按比例放大 `RenderOps` 中的矩形与字号，或在将来引入 `theme.Layout.scale_permille: u16`（千分比）统一乘算。
- **验收**：在 QEMU 固定分辨率下视觉正确；变更 `screen_width/height` 时任务栏贴底、Orb 与托盘相对位置保持（见 `theme.Layout`）。

## 后续

- 每监视器 DPI、非客户区缩放与 `GetDpiForWindow` 风格 API 映射到 `Win32Process` / user32（与 [DesktopManagerSpec.md](DesktopManagerSpec.md) 中的子系统表一致）。

## 外部参考索引（用户态显示规范）

姊妹仓库中的 Win32 **`desktop-src`** 文档树（路径形如 `ZirconOSFluentRust/references/win32/desktop-src`）仅作 **ChangeDisplaySettings / 高 DPI / 多显示器** 等**用户态**行为与 MSDN 对照的**长期参考**。**不用于** LoongArch UEFI GOP、`ramfb` 或 QEMU 串口排错；后者见 [AeroDesktopRuntime.md](AeroDesktopRuntime.md)。

**可检索对照**：LoongArch UEFI PE 文本重定位讨论见 [`scripts/tools/PE_LOONGARCH_UEFI.md`](../../scripts/tools/PE_LOONGARCH_UEFI.md) 与 [loongson-community/discussions#108](https://github.com/loongson-community/discussions/issues/108)。与 **`desktop-src`** 无包含关系。
