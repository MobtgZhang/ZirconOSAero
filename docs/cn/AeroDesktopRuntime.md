# Aero 桌面运行时架构与输入调试

本文描述 **QEMU/真机上实际执行的桌面路径**（内核帧缓冲 + 主循环），与 `src/desktop/aero/` 资源库的关系，以及鼠标不移动时的排查顺序。

## 1. 数据流（内核）

1. **`src/main.zig`**：桌面就绪后循环调用 `input_hub.pollAll()`、`mouse.popEvent()`、`display.handleMouseMove` / `handleClick`；按 `scene_dirty` 调用 **`display.renderDesktopFrameEx(scene_dirty)`** 与 `present()`（仅指针动时可走软件光标 save-under 快速路径）。
2. **`src/drivers/input/input_hub.zig`**：`virtio_input_pci.poll()`；在 **x86_64** 上额外 `mouse.poll()`（PS/2）。
3. **`src/drivers/input/virtio_input_pci.zig`**：解析 Linux `input_event`，在 `syncDeliver` 中调用 `mouse.deliverMouseEvent`。
4. **`src/drivers/video/display.zig`**：从 `mouse.getX/Y` 同步平滑坐标；场景合成走 **`renderer_aero.renderFrameEx(false)`**，指针由 **软件光标层**（save-under）叠加。
5. **`src/drivers/video/renderer_aero.zig`**：绘制壁纸预设、桌面图标、Explorer、任务栏、开始菜单等（默认不在此绘制指针，由 `display` 光标层完成）。

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
| 可选 `desktop_bisect=true` | `zig build -Ddesktop_bisect=true`：桌面循环在 `renderDesktopFrameEx` / `present` 前后打 `klog.debug`，用于定位 `integer overflow` 等 panic 落在合成还是提交阶段。 |
| LoongArch | `vm.remapIdentityVirtPageUncached` 与 VirtIO 环 GPA（`virtio_input_pci` 内 H6/H7 注释）。 |
| 真机 USB | 当前内核 **无 USB HID 鼠标驱动**；仅 PS/2 与 VirtIO-Input PCI 可靠。仅 USB 鼠标时请换 PS/2 或在 QEMU 加 virtio-mouse。 |

### 3.1 诊断：逻辑坐标 vs 屏上像素

在按上表确认输入后仍「看不见动」时，按顺序区分：

1. **坐标是否在变**：`MOUSE_DEBUG=true` 时状态条含 `ptr x,y`；或 `AGENT_NDJSON` H4 心跳里的坐标字段。
2. **若坐标不变**：仍是输入/轮询/IRQ 路径（§3 前半）。
3. **若坐标变但画面不动**：查 **`Framebuffer Driver: … double_buf=ON|OFF`**；超大分辨率下应出现 **`heap back buffer`** 日志（连续物理页后备）。再对照 **拖拽窗口** 与静止桌面：拖拽路径曾依赖局部 `flipDirty`，现已并入指针脏矩形。
4. **概念对照**（非实现依赖）：离屏合成与「指针与主画面分离」见仓库内 `mdcs/ideas.md`；本内核实现为 **自研软件光标层 + 双缓冲/按需后备**，不绑定任何第三方 OS 显示 API。

### 3.2 x86_64 UEFI：指针不动时的对齐清单（相对 LoongArch）

在 LoongArch `virt` + `virtio-mouse-pci` 已能移动指针、而 x86 UEFI+QEMU 不动时，按序核对（与 `mdcs/ideas.md` 中「硬件游标 vs 软件回退」预期一致：当前产品路径为 **软件游标**，不动多半是 **事件未进 `mouse.deliverMouseEvent`**）：

| 项 | 说明 |
|----|------|
| QEMU 设备线 | 与 LoongArch 一样挂上 **`-device virtio-mouse-pci`**（及可选 `virtio-keyboard-pci`）；见 `Makefile` 中 `QEMU_COMMON_X86` / 各架构变量。 |
| VirtIO attach | 串口是否出现 **`VirtIO-Input PCI: queue_size=…`**；`Input:` 行 **`VirtIO_Input_PCI=active`**。若无设备，查 PCI 枚举与 `1af4:1052`。 |
| H6/H7（环与缓存） | `virtio_input_pci`：`used.idx` 是否随操作前进；x86_64 与 LoongArch 均可能对环页做 **uncached remap**（源码注释 H6/H7）。`MOUSE_DEBUG=true` 可看队列快照。 |
| `usb_xhci` | x86 默认常 **`USB_XHCI=true`**，LoongArch 构建可能关闭；若怀疑与 VirtIO 并存问题，可 **`zig build -Dusb_xhci=false`** 做 A/B。 |
| PS/2 与 VirtIO 双源 | `input_hub.pollAll` 在 x86 上 **VirtIO + `mouse.poll()`**；`MOUSE_DEBUG` 确认哪一路有增量、是否被「重复包丢弃」误伤。 |
| `DESKTOP_IDLE_SPIN` | x86 桌面循环末尾若为 **`hlt`** 且几乎不唤醒，可设 **`DESKTOP_IDLE_SPIN=true`** 与 LoongArch 短自旋策略对齐后再测。 |

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

- `scripts/desktop-qa.sh`：内核构建 + Aero 库测试（建议加 `MOUSE_DEBUG=true` 做指针/VirtIO 对照）；可配合不同 GOP 分辨率、`display.double_buffer` 开关在配置中的组合做矩阵冒烟。
- `scripts/agent-ingest-serial.sh`：摄取 `AGENT_NDJSON` 日志。
- `docs/cn/DesktopQA.md`、`src/desktop/aero/resources/VISUAL_QA.md`：视觉与交互验收要点。

## 8. AMD / Intel / NVIDIA 显示构建项（与鼠标隔离）

**帧缓冲解析顺序**（`desktop_fb_resolve.zig`）：龙芯（LoongArch）→ **NVIDIA** → Intel → AMD → GOP/ramfb 原样。

| 变量 / zig 选项 | 含义 |
|-----------------|------|
| `NVIDIA_GPU` / `-Dnvidia_gpu` | 是否探测 NVIDIA `0x10DE` 显示类 PCI（x86_64 默认 `true`）。 |
| `NVIDIA_GPU_DEFER_PROBE` / `-Dnvidia_gpu_defer_probe` | 将 NVIDIA PCI/BAR 探测延到首次 `resolveDesktopFramebuffer`。 |
| `NVIDIA_KMS_EXPERIMENTAL` / `-Dnvidia_kms_experimental` | BAR0 首双字只读 peek（调试）；默认关闭，仍 GOP handoff。 |
| `NVIDIA_HDMI_SYNC` / `-Dnvidia_hdmi_sync` | 探测成功后刷新 HDMI 桩主连接器；混合显卡默认 `false`，避免覆盖 Intel/AMD 元数据。 |
| `AMD_IGPU` / `-Damd_igpu` | 是否探测 AMD/ATI `0x1002` 显示类 PCI（默认 `true`）。 |
| `AMD_IGPU_DEFER_PROBE` / `-Damd_igpu_defer_probe` | 将 AMD PCI/BAR 探测延到首次 `resolveDesktopFramebuffer`。 |
| `AMD_KMS_EXPERIMENTAL` / `-Damd_kms_experimental` | AMD 显示 MMIO 可选只读探测路径；默认关闭，仅 GOP handoff。 |
| `INTEL_IGPU` / `-Dintel_igpu` | 是否探测 Intel 8086 显示类 PCI（默认 `false`；Intel 本可 `make INTEL_IGPU=true`）。 |
| `INTEL_IGPU_DEFER_PROBE` / `-Dintel_igpu_defer_probe` | 将 Intel PCI/BAR 探测延到首次 `resolveDesktopFramebuffer`。 |
| `INTEL_KMS_EXPERIMENTAL` / `-Dintel_kms_experimental` | Intel 显示 MMIO 可选探测；默认关闭。 |

驱动日志中 **`NVIDIA=`** / **`AMDDisplay=`** / **`IntelIGPU=`** 均可为 `yes` / `no` / **`defer`**。

**QEMU x86 说明**：默认 `pc` + `-vga std` **不会出现** PCI 厂商 `0x1002` / `0x10DE` 的独立显示控制器；AMD/NVIDIA 探测会静默失败并继续使用 GOP。验证 NVIDIA 路径需 **真机**、**PCI 直通** 或自行在 QEMU 附加含 `10DE:03xx` 的设备。VirtIO 显示为 **`1af4:1050`**（`virtio-gpu-pci`），与本节 NVIDIA 路径不同。

**范围（R7 及以下）**：DID 与芯片族见 `src/drivers/video/amd/dids.zig`、`family_detect.zig`（Stoney / Carrizo / Kaveri / Kabini 等）；未知 DID 仍 handoff，但不走实验性 KMS 分派。

## 9. 双缓冲、大块后备与软件光标层

- **配置**：`config` 中 `display.double_buffer` 为 `false` 时直接绘制屏前缓冲；为 `true` 时优先使用静态后备（≤10MiB 帧），更大则尝试 **`FrameAllocator.allocContiguous`** 申请连续物理页（须已在 `main` 中 `setKernelFrameAllocator`）。
- **Present**：双缓冲下 `present()` 仍对整幅后备做 `memcpy` 到 GOP，避免脏矩形漏画指针区；单缓冲下绘制即屏前，`flipDirty` 主要清脏标记。
- **软件光标层**：场景先合成至绘制缓冲，再在顶层做 save-under（保存指针下像素 → 移动时恢复旧区 → 在新位置绘制）。仅指针移动且壳层无脏时跳过壁纸/窗口重绘；形态变化（如箭头/手型）会回退整场景路径。`display.hardware_cursor` 仅为预留钩子（`notifyHardwareCursorIfAvailable`），供未来接显示控制器 sprite，不涉及任何专有图形栈 API。
- **轻量多缓冲语义**：指针下的像素快照等价于 ideas.md 中「与主帧分离的叠加」的**软件实现**，非 WDDM/DXGI 的 Flip 链。

### 9.1 与 `mdcs/ideas.md`（硬件游标）的边界

`ideas.md` 描述 Windows 7 / WDDM 下 **显卡硬件 Cursor Sprite** 在扫描输出阶段叠加、与 DWM 合成解耦。本仓库内核路径为 **GOP/ramfb + 自绘合成**，无 `DxgkDdiSetPointerShape` 类接口；当前 **`display.notifyHardwareCursorIfAvailable`** 与配置项 **`display.hardware_cursor`** 仅为占位，便于将来接到真实显示迷你端口或固件提供的指针平面时再接硬件 sprite。**预期**：在 QEMU/无专用驱动时，指针始终走 **软件光标层**，延迟与桌面帧率一致；勿与 VirtIO-Input 事件路径混淆。

### 9.2 任务栏与 `ideas.md`（扫描输出前叠加）

Win7 参考模型中，任务栏与指针一样属于「提交到扫描输出前」的壳层元素。本内核中 **整幅由 `renderer_aero` 合成进帧缓冲**，任务栏由 **`display.renderDesktopAeroTaskbar`** 单一路径绘制（毛玻璃走 `dwm.renderGlassEffect` 的 `.taskbar` 分支，无 WDDM 提交队列）。这与 `ideas.md` 第二节「硬件叠加层」仅为**概念对照**：当前无独立扫描硬件层，一切为 CPU 绘制 + `present()`/`flip()`。

## 10. 最小复现建议（串口）

1. `make clean build MOUSE_DEBUG=true`（或 `AGENT_NDJSON=true`）  
2. `make run 2>&1 \| tee /tmp/zircon-serial.log`  
3. 在日志中搜索：`Input:`、`InputDiag:`、`VirtIO-Input PCI`、`Desktop: fb`  
4. 若怀疑 HLT：`make run DESKTOP_IDLE_SPIN=true`  
5. 若遇 **`KERNEL PANIC: integer overflow`** 且需二分：`zig build … -Ddesktop_bisect=true`（或 Makefile 传入等价选项），查看最后一组 `desktop: pre/post renderDesktopFrameEx` 日志。
