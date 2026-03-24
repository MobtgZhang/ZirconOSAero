# Aero 桌面运行时架构与输入调试

本文描述 **QEMU/真机上实际执行的桌面路径**（内核帧缓冲 + 主循环），与 `src/desktop/aero/` 资源库的关系，以及鼠标不移动时的排查顺序。

## 1. 数据流（内核）

1. **`src/main.zig`**：桌面就绪后循环调用 `input_hub.pollAll()`、`mouse.popEvent()`、`display.handleMouseMove` / `handleClick`，按需 `display.renderDesktopFrame()` 与 `present()`。
2. **`src/drivers/input/input_hub.zig`**：`virtio_input_pci.poll()`；在 **x86_64** 上额外 `mouse.poll()`（PS/2）。
3. **`src/drivers/input/virtio_input_pci.zig`**：解析 Linux `input_event`，在 `syncDeliver` 中调用 `mouse.deliverMouseEvent`。
4. **`src/drivers/video/display.zig`**：`renderDesktopFrame` 从 `mouse.getX/Y` 同步光标并调用 **`renderer_aero.renderFrame()`**。
5. **`src/drivers/video/renderer_aero.zig`**：绘制壁纸预设、桌面图标、Explorer、任务栏、开始菜单与光标。

`src/desktop/aero/` 提供 **资源清单**（`resource_loader.zig`）、主题默认值（`dwm_nt61_defaults` 交叉引用）与可复用库；与内核路径的图标 ID、壁纸文件名应对齐。

## 2. 非 x86 上的主循环空闲

`src/arch.zig` 的 `waitForInterrupt` 在 **非 x86_64** 上为短自旋而非 WFI，以便在无完整 IRQ 时仍能轮询 `input_hub`（见源码注释）。若仍无指针移动，应查 VirtIO 是否 attach、环是否前进。

## 3. 鼠标不动：建议判据链

| 步骤 | 检查 |
|------|------|
| 启动日志 | `VirtIO-Input PCI` 是否成功 attach；是否出现 `no 1af4:1052`（缺设备）。 |
| 模拟器 | Makefile 中各架构的 `virtio-mouse-pci` / `virtio-keyboard-pci` 是否与当前 `ARCH` 一致。 |
| 可选 `MOUSE_DEBUG=true` | 串口 `mouseDbg`：`desktop tick` 是否递增、`virtio inst` 的 `used.idx` 是否随操作变化；`syncDeliver total` 是否增长。 |
| 可选 `AGENT_NDJSON=true` | 串口 `AGENT_LOG:` 行；`hypothesisId` 含义见 `src/debug/agent_ndjson.zig` 文件头（H1/H2/H3/H4/H6/H7）。宿主机：`scripts/agent-ingest-serial.sh`。 |
| LoongArch | `vm.remapIdentityVirtPageUncached` 与 VirtIO 环 GPA（`virtio_input_pci` 内 H6/H7 注释）。 |

## 4. QEMU 与输入设备（摘要）

- **x86_64**：`make run` 使用的 `QEMU_*` 变量见根目录 `Makefile`（含 `-device virtio-mouse-pci` 等）。
- **LoongArch**：`LOONGARCH64_QEMU_MODE`、`QEMU_LOONGARCH64_VIRTIO_INPUT` 等见 `Makefile` 与 `build.conf`。
- 若使用 **virtio-tablet** 且宿主机未抓取指针，部分 UI 仅产生 ABS；本驱动已合并 ABS 位移，但仍建议优先验证 **virtio-mouse-pci** 与串口日志。

## 5. 桌面快捷键（壳层）

- **Ctrl+Shift+Esc**：任务管理器（x86：PS/2；VirtIO 键盘：`evdev_virtio_bridge`）。
- **Ctrl+Alt+F9**：循环 **Aero 壁纸预设**（与 `resource_loader` 内置壁纸条目顺序对应的程序化背景；非 SVG 光栅化）。

## 6. 颜色与主题单一源

- **DWM 数值**：`src/config/dwm_nt61_defaults.zig`。
- **内核 `theme.rgb`**：`b | (g<<8) | (r<<16)`（Win32 COLORREF 风格）。
- **Aero 库 `desktop/aero/src/theme.zig` 的 `rgb`**：分量顺序相反，勿混用字面量。

## 7. 相关脚本与文档

- `scripts/desktop-qa.sh`：内核构建 + Aero 库测试。
- `scripts/agent-ingest-serial.sh`：摄取 `AGENT_NDJSON` 日志。
- `docs/cn/DesktopQA.md`、`src/desktop/aero/resources/VISUAL_QA.md`：视觉与交互验收要点。
