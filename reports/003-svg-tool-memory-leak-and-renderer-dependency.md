# 问题 #3：SVG 转换工具缺少备用渲染器且临时文件名内存泄漏

## 1. 问题编号

`3`

## 2. 问题位置

- 文件路径：`tools/svg_to_rgba.zig`
- 函数/模块：`convertSvgToRgbaWith`、`convertSvgToRgba`
- 行号或代码片段：原实现仅尝试 `rsvg-convert`，且 Inkscape 分支中的嵌套 `allocPrint` 结果未释放。

## 3. 问题描述

构建主机未安装 `rsvg-convert` 而安装了 `inkscape` 时，SVG 转 RGBA 工具会因找不到首选渲染器而直接失败。即使切到 Inkscape，旧实现为临时 PNG 文件名分配的字符串也没有释放，造成构建工具内存泄漏。PNG 解码路径还曾使用低层 `decodePixels` 接口，未完成 `PixelBuffer` 生命周期清理。

## 4. 复现路径

在缺少 `rsvg-convert`、但存在 `inkscape` 的构建主机上执行：

```text
zig build -Darch=x86_64
```

旧实现会在资源生成阶段因 `rsvg-convert` 不存在而失败；若通过调试方式强制走 Inkscape 分支，`zircon-svg-*.png` 文件名字符串会在每次转换后泄漏。

## 5. 影响范围

- 阻塞资源生成和完整内核镜像构建。
- 构建主机依赖选择过窄，无法在只有 Inkscape 的环境中复现构建。
- 构建工具使用 `GeneralPurposeAllocator`，每次转换泄漏临时文件名字符串，增加长流程构建的内存占用。

## 6. 严重程度

- Medium

## 7. 可能原因

工具最初只假设 `rsvg-convert` 可用。Inkscape 回退逻辑后续添加时，使用嵌套 `allocPrint` 组合 `/tmp` 路径，但没有为外层结果添加释放逻辑。PNG 数据处理也未按 Zig 图像库返回的 `PixelBuffer` 生命周期约定统一清理。

## 8. 权威参考依据

- 项目源码：`tools/svg_to_rgba.zig` 中 `convertSvgToRgbaWith` 使用 `GeneralPurposeAllocator`，并通过 `std.process.Child.run` 调用外部渲染器。
- 本机工具链实测：`rsvg-convert` 不可用，`inkscape` 为 `Inkscape 1.4.3`。
- Zig 构建实测：修复前 `zig build -Darch=x86_64` 因缺少 `rsvg-convert` 失败；修复后构建成功且无 GPA 泄漏报告。
- 本问题属于项目构建工具链，不涉及 Windows 7 二进制可观察行为，因此不引用 REA 结论。
- `/home/mobtgzhang/api.json` 是 REA 接入配置，不包含 Windows API 行为描述，不能作为本问题的依据。

## 9. 建议修复方案

- 在 `convertSvgToRgba` 中捕获 `rsvg-convert` 返回的 `error.FileNotFound` 后尝试 `inkscape`。
- Inkscape 分支显式释放外层 `allocPrint` 生成的临时 PNG 文件名和完整路径。
- 使用返回 `PixelBuffer` 的 `png.decode`，并在调用侧通过 `rgba.free(allocator)` 释放位图。
- 保持 Inkscape 输出为独立临时 PNG，避免其 `-f png` 的标准输出模式造成误解码风险。

## 10. 验证方法

- 运行 `zig build -Darch=x86_64`，确认资源生成和构建均成功。
- 确认 `GeneralPurposeAllocator.deinit` 没有报告泄漏。
- 运行 `python3 tests/run_all.py --suite config` 与 `python3 tests/run_all.py --suite boot`，确认构建配置和启动组合回归通过。
- 后续可在干净容器中分别安装 `rsvg-convert` 或 `inkscape` 验证两条渲染路径。

## 11. 状态

- Fixed

## 12. 修复说明

已实现 `rsvg-convert` 到 `inkscape` 的回退，释放 Inkscape 分支的临时文件名路径，并将 PNG 解码改为受 `PixelBuffer` 生命周期管理的 `png.decode`。该修复只影响宿主构建工具，不改变内核或驱动接口。
