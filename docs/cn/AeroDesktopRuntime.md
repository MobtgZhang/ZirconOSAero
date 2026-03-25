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

**x86_64 桌面**默认在循环末尾调用 `waitForInterruptDesktop()`：通常为 `sti` + `hlt`，依赖 PIC 上键鼠/定时器 IRQ 唤醒。若怀疑 IF/PIC/虚拟化导致几乎不唤醒，可用 **`DESKTOP_IDLE_SPIN=true`**（`make` / `build.conf` / `zig build -Ddesktop_idle_spin=true`）改为短自旋空闲，对照指针是否恢复。

## 3. 鼠标不动：建议判据链

| 步骤 | 检查 |
|------|------|
| 启动日志 | `VirtIO-Input PCI` 是否成功 attach；是否出现 `no 1af4:1052`（缺设备）。 |
| 启动日志 | **`Input:`** 行：`VirtIO_Input_PCI=active|inactive`，**`PS2_hw=ok|no`**。 |
| 启动日志 | **`InputDiag:`** 行：当前 `MOUSE_DEBUG` / `AGENT_NDJSON` / `AMD_IGPU` / `amd_defer` / `INTEL_IGPU` / `intel_defer` / `idle_spin` 开关摘要。 |
| 启动日志 | 进入桌面后 **`Desktop: fb … mouse=(x,y) bounds=`**：若坐标长期卡角点且 bounds 与 GOP 不一致，可能被 `clampPosition` 钉死。 |
| 模拟器 | Makefile 中各架构的 `virtio-mouse-pci` / `virtio-keyboard-pci` 是否与当前 `ARCH` 一致；**勿删掉** `QEMU_COMMON_X86` 中的 virtio-input（见 `Makefile` 注释）。 |
| 隔离 AMD | **`make AMD_IGPU=false`**（或 `zig build -Damd_igpu=false`）重建：排除 AMD PCI/BAR 探测路径。 |
| 隔离 Intel | **`make INTEL_IGPU=false`**（默认已为 false）；若开启过 Intel，可关以排除 8086 探测。 |
| 可选 `MOUSE_DEBUG=true` | 串口 `mouseDbg`：`desktop tick` 是否递增、`virtio inst` 的 `used.idx` 是否随操作变化；`syncDeliver total` 是否增长。 |
| 可选 `AGENT_NDJSON=true` | 串口 `AGENT_LOG:` 行；`hypothesisId` 含义见 `src/debug/agent_ndjson.zig` 文件头（H1/H2/H3/H4/H6/H7）。宿主机：`scripts/agent-ingest-serial.sh`。 |
| LoongArch | `vm.remapIdentityVirtPageUncached` 与 VirtIO 环 GPA（`virtio_input_pci` 内 H6/H7 注释）。 |
| 真机 USB | 当前内核 **无 USB HID 鼠标驱动**；仅 PS/2 与 VirtIO-Input PCI 可靠。仅 USB 鼠标时请换 PS/2 或在 QEMU 加 virtio-mouse。 |

## 4. QEMU 与输入设备（摘要）

- **x86_64**：`make run` 默认 `QEMU_COMMON_X86`：`grab-on-hover=on`（`QEMU_GTK_EXTRA=` 可关）、**virtio-mouse + virtio-keyboard + virtio-tablet**；tablet 在未抓取时常见 ABS，驱动将连续 ABS 差分当作位移。
- **DESKTOP_IDLE_SPIN**：`Makefile` 默认 `true`（短自旋代替桌面循环里的 `hlt`）；不需要时可 `DESKTOP_IDLE_SPIN=false`。
- **LoongArch** 等：`LOONGARCH64_QEMU_MODE`、`QEMU_LOONGARCH64_VIRTIO_INPUT` 等见 `Makefile` 与 `build.conf`。

## 5. 桌面快捷键（壳层）

- **Ctrl+Shift+Esc**：任务管理器（x86：PS/2；VirtIO 键盘：`evdev_virtio_bridge`）。
- **Ctrl+Alt+F9**：循环 **Aero 壁纸预设**（与 `resource_loader` 内置壁纸条目顺序对应的程序化背景；非 SVG 光栅化）。

## 6. 颜色与主题单一源

- **DWM 数值**：`src/config/dwm_nt61_defaults.zig`。
- **内核 `theme.rgb`**：`b | (g<<8) | (r<<16)`（Win32 COLORREF 风格）。
- **Aero 库 `desktop/aero/src/theme.zig` 的 `rgb`**：分量顺序相反，勿混用字面量。

## 7. 相关脚本与文档

- `scripts/desktop-qa.sh`：内核构建 + Aero 库测试（建议加 `MOUSE_DEBUG=true` 做指针/VirtIO 对照）。
- `scripts/agent-ingest-serial.sh`：摄取 `AGENT_NDJSON` 日志。
- `docs/cn/DesktopQA.md`、`src/desktop/aero/resources/VISUAL_QA.md`：视觉与交互验收要点。

## 8. AMD / Intel 核显构建项（与鼠标隔离）

**帧缓冲解析顺序**（`desktop_fb_resolve.zig`）：先 AMD，再 Intel，最后 GOP 原样。

| 变量 / zig 选项 | 含义 |
|-----------------|------|
| `AMD_IGPU` / `-Damd_igpu` | 是否探测 AMD/ATI `0x1002` 显示类 PCI（默认 `true`）。 |
| `AMD_IGPU_DEFER_PROBE` / `-Damd_igpu_defer_probe` | 将 AMD PCI/BAR 探测延到首次 `resolveDesktopFramebuffer`。 |
| `AMD_KMS_EXPERIMENTAL` / `-Damd_kms_experimental` | AMD 显示 MMIO 可选只读探测路径；默认关闭，仅 GOP handoff。 |
| `INTEL_IGPU` / `-Dintel_igpu` | 是否探测 Intel 8086 显示类 PCI（默认 `false`；Intel 本可 `make INTEL_IGPU=true`）。 |
| `INTEL_IGPU_DEFER_PROBE` / `-Dintel_igpu_defer_probe` | 将 Intel PCI/BAR 探测延到首次 `resolveDesktopFramebuffer`。 |
| `INTEL_KMS_EXPERIMENTAL` / `-Dintel_kms_experimental` | Intel 显示 MMIO 可选探测；默认关闭。 |

驱动日志中 **`AMDIGPU=`** / **`IntelIGPU=`** 均可为 `yes` / `no` / **`defer`**。

**QEMU x86 说明**：默认 `pc` + `-vga std` **不会出现** PCI 厂商 `0x1002` 的 VGA 显示控制器；AMD 探测会静默失败并继续使用 GOP。验证 AMD 路径需 **真机 APU** 或 **PCI 直通** 等环境。

**范围（R7 及以下）**：DID 与芯片族见 `src/drivers/video/amd/dids.zig`、`family_detect.zig`（Stoney / Carrizo / Kaveri / Kabini 等）；未知 DID 仍 handoff，但不走实验性 KMS 分派。

## 9. 最小复现建议（串口）

1. `make clean build MOUSE_DEBUG=true`（或 `AGENT_NDJSON=true`）  
2. `make run 2>&1 \| tee /tmp/zircon-serial.log`  
3. 在日志中搜索：`Input:`、`InputDiag:`、`VirtIO-Input PCI`、`Desktop: fb`  
4. 若怀疑 HLT：`make run DESKTOP_IDLE_SPIN=true`
