# Aero 桌面运行时架构与输入调试

本文描述 **QEMU/真机上实际执行的桌面路径**（内核帧缓冲 + 主循环），与 `src/desktop/aero/` 资源库的关系，以及鼠标不移动时的排查顺序。

## 1. 数据流（内核）

1. **`src/main.zig`**：桌面就绪后循环调用 `input_hub.pollAll()`、`mouse.popEvent()`、`display.handleMouseMove` / `handleClick`；按 **`display.renderDesktopFrameEx(scene_dirty, caption_chrome_only, drag_repaint, startmenu_repaint)`** 与 `present()`。拖窗位移走 **`needs_drag_repaint`**（`renderDragFrame`）；开始菜单 **仅悬停行变化** 时走 **`needs_startmenu_repaint`**（Harmony 壁纸预设下 `renderer_aero.redrawStartMenuRegionOnly`，避免整屏重绘）；整场景由 UI 脏、插值、`needs_full_scene` 等驱动。
2. **`src/drivers/input/input_hub.zig`**：`virtio_input_pci.poll()`；在 **x86_64** 上仅当 **未** attach VirtIO-Input PCI 时调用 `mouse.poll()`（PS/2）。**IRQ12** 在 `arch/x86_64/mod.zig` 的 `handleMouseIrq` 中同样跳过，避免与 QEMU 默认 virtio-mouse/tablet 双源叠加位移。
3. **`src/drivers/input/virtio_input_pci.zig`**：解析 Linux `input_event`，在 `syncDeliver` 中调用 `mouse.deliverMouseEvent`。
4. **`src/drivers/video/display.zig`**：从 `mouse.getX/Y` 同步平滑坐标；场景合成走 **`renderer_aero.renderFrameEx(false)`**，指针由 **软件光标层**（save-under）叠加。
5. **`src/drivers/video/renderer_aero.zig`**：绘制壁纸预设、桌面图标、Explorer、任务栏、开始菜单等（默认不在此绘制指针，由 `display` 光标层完成）。

`src/desktop/aero/` 提供 **资源清单**（`resource_loader.zig`）、主题默认值（`zircon_aero_defaults` 交叉引用）与可复用库；与内核路径的图标 ID、壁纸文件名应对齐。

## 2. 非 x86 上的主循环空闲

`src/arch.zig` 的 `waitForInterrupt` 在 **非 x86_64** 上为短自旋而非 WFI，以便在无完整 IRQ 时仍能轮询 `input_hub`（见源码注释）。若仍无指针移动，应查 VirtIO 是否 attach、环是否前进。

**LoongArch64**：`waitForInterruptDesktop()` **始终**短自旋（与 `idle 0` 依赖定时器/中断唤醒的路径解耦）。VirtIO-Input 当前以 **MMIO 轮询**为主；若 PCH/LIOINTC 未把设备 MSI/线 IRQ 可靠接到 `ke/interrupt_loongarch.zig`，指针更新频率会接近主循环吞吐而非「每设备中断一帧」。缓解：`main.zig` 在 `waitForInterruptDesktop` 前对 LoongArch 做 **更多轮** `input_hub.pollAll()`（高于 x86 的 16 次），并依赖 `virtio_input_pci.poll()` 的双遍排空。

**x86_64 桌面**默认在循环末尾调用 `waitForInterruptDesktop()`：`-Ddesktop_idle_spin=true`（**默认**）时为短自旋，利于 QEMU 下 VirtIO/8042 与轮询对齐；**`desktop_idle_spin=false`** 时为 `sti` + `hlt`，须保证 **PIC/APIC 上 IRQ1/IRQ12 及所用 VirtIO 线/MSI** 能唤醒 CPU，否则指针会与定时器 tick 同步卡顿。若怀疑 IF/PIC/虚拟化导致几乎不唤醒，请保持 **`DESKTOP_IDLE_SPIN=true`** 或修复中断路由后再关 spin。

## 3. 鼠标不动：建议判据链

| 步骤 | 检查 |
|------|------|
| 启动日志 | `VirtIO-Input PCI` 是否成功 attach；是否出现 `no 1af4:1052`（缺设备）。 |
| 启动日志 | **`Input:`** 行：`VirtIO_Input_PCI=active|inactive`，**`PS2_hw=ok|no`**。 |
| 启动日志 | **`InputDiag:`** 行：当前 `MOUSE_DEBUG` / `AGENT_NDJSON` / `AMD_IGPU` / `amd_defer` / `INTEL_IGPU` / `intel_defer` / `idle_spin` 开关摘要。 |
| 启动日志 | 进入桌面后 **`Desktop: fb … mouse=(x,y) bounds=`**：若坐标长期卡角点且 bounds 与 GOP 不一致，可能被 `clampPosition` 钉死。 |
| 模拟器 | Makefile 中各架构的 **`virtio-mouse-pci`** / `virtio-keyboard-pci` 是否与当前 `ARCH` 一致；**勿删掉** `QEMU_COMMON_X86` 中的 virtio-input（见 `Makefile` 注释）。`DESKTOP_IDLE_SPIN` 在 Makefile 默认 **`true`**（与 `build.zig` `-Ddesktop_idle_spin` 一致），桌面循环短自旋而非 `hlt`，利于 QEMU 下 VirtIO/PS/2 轮询。 |
| 隔离 AMD | **`make AMD_IGPU=false`**（或 `zig build -Damd_igpu=false`）重建：排除 AMD PCI/BAR 探测路径。 |
| 隔离 Intel | **`make INTEL_IGPU=false`**（默认已为 false）；若开启过 Intel，可关以排除 8086 探测。 |
| 可选 `MOUSE_DEBUG=true` | 串口 `mouseDbg`：`desktop tick` 是否递增、`virtio inst` 的 `used.idx` 是否随操作变化；`syncDeliver total` 是否增长。 |
| 可选 `AGENT_NDJSON=true` | 串口 `AGENT_LOG:` 行；`hypothesisId` 含义见 `src/debug/agent_ndjson.zig` 文件头（H1/H2/H3/H4/H6/H7）。宿主机：`scripts/agent-ingest-serial.sh`。 |
| 可选 `desktop_bisect=true` | `zig build -Ddesktop_bisect=true`：桌面循环在 `renderDesktopFrameEx` 前后打 `klog.debug`，并输出 **`scheduler` tick 差**（合成耗时量级）与 **`fb_w`**；`present` 前仍有日志，用于区分 panic 落在合成还是提交阶段。 |
| 卡顿像「冻住」 | 多为 **单帧 CPU 盒式模糊过长**（高分 GOP）。串口查 **`DesktopGOP:`** 宽高 pitch；调低 `zircon_aero_defaults` 中 blur 相关常量或见 [DesktopManagerSpec.md](DesktopManagerSpec.md) 第 8 节。 |
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
| VirtIO attach | 串口是否出现 **`VirtIO-Input PCI: queue_size=…`**；`Input:` 行 **`VirtIO_Input_PCI=active`**。若无设备，查 PCI 枚举与 `1af4:1052`（x86_64 上枚举 **bus 0–2**，兼容 pci-bridge 机型）。 |
| H6/H7（环与缓存） | `virtio_input_pci`：`used.idx` 是否随操作前进；x86_64 与 LoongArch 均可能对环页做 **uncached remap**（源码注释 H6/H7）。`MOUSE_DEBUG=true` 可看队列快照。 |
| `usb_xhci` | x86 默认常 **`USB_XHCI=true`**，LoongArch 构建可能关闭；若怀疑与 VirtIO 并存问题，可 **`zig build -Dusb_xhci=false`** 做 A/B。 |
| PS/2 与 VirtIO 双源 | `input_hub.pollAll`：x86 上 **VirtIO attach 时不**再轮询 PS/2；仅无 `1af4:1052` 时走 **8042**。若自定义 QEMU 只挂 `virtio-keyboard-pci` 而无鼠标类 VirtIO，须保留 PS/2 或增加 `virtio-mouse-pci`。 |
| `DESKTOP_IDLE_SPIN` | x86 桌面循环末尾若为 **`hlt`** 且几乎不唤醒，可设 **`DESKTOP_IDLE_SPIN=true`** 与 LoongArch 短自旋策略对齐后再测。 |

## 4. QEMU 与输入设备（摘要）

### 4.1 各架构设备矩阵（与 `Makefile` 对齐）

| 架构 | 主要 Makefile 片段 | 显示后端（典型） | 指针 / 键盘 VirtIO | 备注 |
|------|-------------------|------------------|-------------------|------|
| **x86_64** | `QEMU_COMMON_X86` | `-display gtk,…` + `-vga std` | `virtio-mouse-pci`、`virtio-keyboard-pci`、`virtio-tablet-pci` | `QEMU_GTK_EXTRA` 默认 `,grab-on-hover=on`；置空可关「移入即抓取」。REL 型 mouse 未抓取时常无位移；tablet 多走 **ABS**，内核在 `EV_SYN` 按当前屏宽高映射到像素（非原始 ABS 差分当像素）。 |
| **AArch64** | `QEMU_COMMON_AARCH64` + `QEMU_AARCH64_DEVICES` | **默认** `AARCH64_QEMU_VIRTIO_GPU=0`：仅 `ramfb` + `virtio-mouse-pci` + `virtio-keyboard-pci`（**不**绑 display）+ xhci + `usb-kbd`；`=1` 时 `virtio-gpu-pci`+`ramfb` + tablet/keyboard 绑 `display=zircon_vgpu` | 默认路径 GTK 扫 **ramfb**，避免 “Display output is not active”；ZBM 方向键走全局 VirtIO/USB。 |
| **riscv64** | `QEMU_RISCV64_EXTRA` | **默认** `RISCV64_QEMU_VIRTIO_GPU=0`：与 AArch64 相同（ramfb + REL 键鼠）；`=1` 时 virtio-gpu + 绑 display（易未激活控制台） | 同左 | 需要固件 GOP 实验时再设 `*_QEMU_VIRTIO_GPU=1`。 |
| **LoongArch64** | `QEMU_LOONGARCH64_DEVICES` | **`LOONGARCH64_QEMU_VIRTIO_GPU=0`（Makefile 默认）** → 仅 ramfb + mouse + keyboard；`=1` → ramfb + virtio-gpu + 键鼠 | 同左 | `LOONGARCH64_VIRT_GRAPHICS` 控制固件 GOP 与 ramfb 并存策略；实验矩阵见 `Makefile` LoongArch 显示注释。 |

### 4.2 行为摘要

- **x86_64**：`make run` 默认 `QEMU_COMMON_X86`：`grab-on-hover=on`（`QEMU_GTK_EXTRA=` 可关）、**virtio-mouse + virtio-keyboard + virtio-tablet**；**显示几何**变更时调用 `drivers.notifyDisplayGeometryChanged`（`initDesktopMode`、`user32.syncScreenFromFramebuffer`），会重置 VirtIO ABS 基线并 `syncCursorFromMouse`。
- **DESKTOP_IDLE_SPIN**：`Makefile` 默认 `true`（短自旋代替桌面循环里的 `hlt`）；不需要时可 `DESKTOP_IDLE_SPIN=false`。
- **LoongArch** 等：`LOONGARCH64_QEMU_MODE`、`QEMU_LOONGARCH64_VIRTIO_INPUT` 等见 `Makefile` 与 `build.conf`。

### 4.2.1 分辨率单一来源（`build.conf` → sync → 嵌入配置 / 内核）

- **权威项**：仓库根目录 **`build.conf`** 中**唯一生效**的一行 **`RESOLUTION=WxHxdepth`**（例 `1920x1080x32`）。
- **`make build`** / **`make sync-resolution`** 会运行 **`scripts/sync_resolution_config.py`**，将宽高（及 bpp）写入：
  - **`config/desktop.conf`** / **`src/config/desktop.conf`** 的 **`[resolution]`**；
  - **`config/boot.conf`** / **`src/config/boot.conf`** 的 **`[grub] gfxmode`**、**`[uefi] resolution`**；
  - **`config/system.conf`** / **`src/config/system.conf`** 的 **`[display] default_width` / `default_height` / `default_bpp`**（与串口早期 **`[display]`** 日志一致）；
  - **`build/tmp/zircon_pref_fb.h`**（LoongArch C stub）、**`build/tmp/kernel_pref_fb_wh.txt`**。
- **`zig build`**：`build.zig` 优先读 **`build.conf`** 中的 **`RESOLUTION`**，其次读 **`kernel_pref_fb_wh.txt`**；可选 **`-Dzbm_preferred_fb_width/height`** 覆盖。不经 `make` 直接 `zig build` 时，若改动了 `build.conf` 但未跑 sync，C stub 头文件可能仍旧，LoongArch UEFI 请以 **`make build`** 或至少 **`make sync-resolution`** 为准。
- **QEMU 内存**：`make run-loongarch64` 使用 **`QEMU_MEM_LOONGARCH64`**（Makefile 默认 1536M，且须 **>1G** 以满足 EDK2 virt）。根目录 **`build.conf`** 中的 **`QEMU_MEM`**（如 8G）作用于 x86_64 / AArch64 / RISC-V 等目标，**不**自动传给 LoongArch；要增大 LoongArch 客体 RAM 请设 **`QEMU_MEM_LOONGARCH64`**（命令行或 `build.conf` 若已 `-include` 进 Makefile）。
- **症状对照（是否「进了桌面」）**：QEMU **固件文本控制台**上出现 **`Firmware GOP … < build preferred …`**、**`Kernel draws at preferred size via ramfb+fw_cfg`**（C stub）或 Zig ZBM 的 **`Handoff has no GOP FB; kernel uses ramfb+fw_cfg`** **不代表**启动失败：意为 handoff 未带 GOP，内核按 **`build.conf` 首选** 走 **ramfb**。请以**串口**为准：若出现 **`ramfb:`**、**`Framebuffer Driver: WxH`**、**`Desktop: fb`**、**`user32: Screen synced`**、**`dwm.exe`** / **`first frame presented`**，则桌面路径已起来。固件小窗可能仍停在 UEFI 文案，而 **GTK 主窗口**扫的是 ramfb/virtio 扫描输出，属常见「双表面」现象。若串口有上述行而 **主窗口全黑**，见下文 **4.2.1.2**（宿主机图形栈）。

#### 正式验收标准（LoongArch / QEMU，团队约定）

1. **「已进桌面」以串口关键字为准**，不以固件 ConOut 小窗是否刷新为准：`ramfb:`（或等价的扫描配置日志）、**`Desktop: fb`**、**`Desktop: first frame presented`** 等。
2. **GUI 仅作辅助**：固件字体易把字母 **O** 与数字 **0** 混淆，勿据此推断 GOP 宽高写错；与 **§9 双缓冲 / 软件光标** 及上文「双表面」一致。
3. **`first frame presented` 之后的 `KERNEL PANIC: integer overflow`**：按 **Debug 下有符号整数溢出** 排查桌面主循环与合成路径（见 **`desktop_bisect`**），与「GOP 未达首选」无必然关系。已审计路径：`src/drivers/input/mouse.zig`（插值差分用 i64）、`framebuffer.zig` 的 **`pixelByteOffset`**（u64 中间量）、`display.zig` 中多处 **i64 矩形/钳位**；若仍复现，用 **`-Ddesktop_bisect=true`** 区分 panic 落在 **`renderDesktopFrameEx`** 与 **`present`** 之间，并继续查 **`renderer_aero.zig`** 等窄化后的热点。
4. **串口已证明首选分辨率 + 首帧成功，但 QEMU 主窗仍只见 UEFI 固件文字**：优先改 **QEMU 设备矩阵**（**`LOONGARCH64_QEMU_VIRTIO_GPU`**、**`-display gtk` / `sdl` / `vnc`**、**`GDK_BACKEND=x11`**、**View → 切换 Display**），**不要**为了「让窗口里变大」去反复改 **`build.conf` 的 `RESOLUTION`** 注入逻辑——在串口已显示与首选一致时，问题多在宿主扫哪块显存，而非构建期宽高未生效。

#### 4.2.1.0 LoongArch：切换 `RESOLUTION` 检查表

| 步骤 | 动作 |
|------|------|
| 1 | 在 **`build.conf`** 只保留一行未注释的 **`RESOLUTION=WxHx32`**。 |
| 2 | 执行 **`make sync-resolution`** 或 **`make build`**（会先 sync）。 |
| 3 | 重建内核与 ZBM：**`make build ARCH=loongarch64`**（或至少 **`zig build -Darch=loongarch64`** + **`make build-zbm-loongarch-uefi`**；后者已依赖 **`sync-resolution`**）。 |
| 4 | QEMU：默认 **`LOONGARCH64_QEMU_VIRTIO_GPU=0`**（仅 ramfb）；若需固件 VirtIO GOP 实验再设 **`=1`**；黑窗时调 **`QEMU_LOONGARCH64_GTK_OPTS`**（含 **`show-tabs=on`** 时切换标签找 ramfb）、**`LOONGARCH64_VIRT_GRAPHICS`**（`Makefile` / `build.conf`）。 |
| 5 | 冒烟：多档分辨率可用 **`bash scripts/test_loongarch_resolution_matrix.sh`**（全表）或 **`--quick`**（CI 三档）。 |

#### 4.2.1.1 LoongArch64 UEFI：GOP 与 ramfb 为何常不一致

- QEMU **LoongArch virt** 所用 **EDK2** 的 **GOP** 常见最大模式为 **1024×768**（或仍非线性/Blt），**达不到** `build.conf` 里的 **1920×1080** 等首选分辨率。
- **C stub / ZBM** 在 **`boot/stub/efi_stub.c`** 等处的策略是：仅当 GOP **同时达到构建首选宽高** 才把 GOP 写入 handoff；否则内核 **弃用该 GOP**，通过 **`ramfb` + `fw_cfg`** 按 **构建首选分辨率** 配置客户机帧缓冲（与 **`main.zig`**、**`hal/loongarch64/ramfb.zig`** 一致）。
- 因此固件 **ConOut 文本窗**上可能仍显示 **「GOP 小于首选 / ramfb」** 类说明，而**实际桌面扫屏**由 **ramfb**（`0x0F000000` 起）在 **首选 WxH** 完成。以串口 **`ramfb:`** / **`Desktop: fb`** / **`first frame presented`** 为准即可。**不要**仅凭 UEFI 窗仍像「卡在启动界面」判断失败。
- **ramfb 初始化失败**时串口会出现 **`ramfb: setupWithDims failed`**：请确认 QEMU 命令行含 **`-device ramfb`**，且客体内存覆盖 **`[0x0F000000, 0x0F000000+fb_size)`**（默认 `Makefile` 的 LoongArch 设备线已含 ramfb）。
- **`LOONGARCH64_QEMU_VIRTIO_GPU=1`** 时走 virtio-gpu 与 ramfb 的另一套组合，部分环境下 GTK 主窗口可能未激活，见 **`Makefile`** 中 **`QEMU_LOONGARCH64_*`** 注释；Zig ZBM 路径下还可能出现 **`[!] GOP: active mode != build preferred …`**。
- **ramfb 物理布局**：QEMU `ramfb` 使用固定 GPA **`0x0F000000`**（见 [`src/hal/loongarch64/ramfb.zig`](../../src/hal/loongarch64/ramfb.zig)）。4K 线性约 **32MiB** 连续区；内核在启用 ramfb 前 **`markPhysRangeUsed`**，避免页表帧与扫描缓冲重叠。串口若出现 **`ramfb: large scanout ~… MiB`** 为提示性日志。

#### 4.2.1.1a QEMU 显示对照（DISPI / GOP / ramfb，与仓库根 [`idea1.md`](../../idea1.md) 对齐）

| 概念 | 在 QEMU LoongArch `virt` 下的含义 | 与本仓库关系 |
|------|-----------------------------------|---------------|
| **Bochs DISPI**（stdvga 等） | 固件/虚拟显卡侧用寄存器设宽高色深；**初始模式常为 1024×768** 量级 | 解释「为何固件 GOP 小」；**不是**内核 `build.conf` 未生效 |
| **UEFI GOP** | 固件报告的**线性帧缓冲**与模式表；可能小于构建首选 | **Handoff** 仅在「GOP ≥ 构建首选」时带 FB；否则内核弃用 GOP |
| **`ramfb` + `fw_cfg`** | **独立**于 ConOut 文本面的客户机物理帧缓冲；QEMU 扫描到 GTK/SDL | 内核 **`pointRamfbToGuestPhys`** 把扫描指向首选分辨率画布；**串口 `ramfb:`** 为成功标志 |
| **virtio-gpu** | 另一显示设备；与 ramfb **并存**时，**哪个绑定主窗口**依赖 QEMU 版本与设备组合 | 调 **`LOONGARCH64_QEMU_VIRTIO_GPU=0/1`**、**`-display gtk` / `sdl` / `vnc`** 做 A/B；见 **`Makefile`** 中 **`QEMU_LOONGARCH64_*`** 注释 |

**结论**：**ConOut 文本窗**与 **ramfb / GOP 扫描输出**不必是同一物理面；串口已 **`Desktop: first frame presented`** 而固件窗仍像停在启动说明上，多属**宿主显示路由**或字体误读，不是「未进桌面」。

#### 4.2.1.2 串口已有 `dwm.exe` / `Desktop: fb` 但 QEMU GTK 窗口全黑（宿主机侧）

与 **`RESOLUTION` 是否注入无关**：内核与 ramfb 已按日志工作，问题多在 **宿主机图形栈**。

- 在 **Wayland** 会话下 GTK/QEMU 偶发黑窗：尝试在 **X11** 会话启动终端后再 `make run`，或 **`GDK_BACKEND=x11`**（视发行版与 QEMU 构建而定）。
- 关闭 **分数缩放 / 200% 缩放** 或换显示器配置试一次。
- 将 **`Makefile`** 里 LoongArch 的 **`-display gtk,…`** 临时改为 **`-display sdl`** 或 **`-vnc :1`**（用 `vncviewer localhost:5901` 看画面）做对照。
- **GTK 多标签**：默认 **`QEMU_LOONGARCH64_GTK_OPTS`** 含 **`show-tabs=on`**；若主标签仍是 UEFI 字而串口已有 **`Desktop: first frame`**，在 QEMU 窗口顶部 **切换到另一显示标签**（常为 ramfb 扫描输出）。
- 确认 **`LOONGARCH64_VIRT_GRAPHICS=on`**（`build.conf` / `Makefile`），且命令行仍带 **`-device ramfb`**（默认 `QEMU_LOONGARCH64_DEVICES` 已含）。

### 4.2.2 AArch64 桌面与 VirtIO-GPU：预期说明

- **默认 QEMU 目标（`AARCH64_QEMU_VIRTIO_GPU=0`）不依赖** 内核 **VirtIO-GPU PCI（1af4:1050）** 驱动。可见桌面路径为：**UEFI GOP 线性帧缓冲**（Multiboot2 传递）与/或 **`ramfb` + `fw_cfg`**（[`src/hal/aarch64/ramfb.zig`](../../src/hal/aarch64/ramfb.zig)），由 [`src/main.zig`](../../src/main.zig) Phase 1 组合。
- 若 **`AARCH64_QEMU_VIRTIO_GPU=1`** 且希望 GTK **主窗口**走 virtio-gpu，需要**单独的 GPU 驱动里程碑**（见 [`docs/cn/DriverMilestones_NT61.md`](DriverMilestones_NT61.md)）；在驱动就绪前应继续以 **ramfb** 为主显示后端。
- **分辨率**：以根目录 **`build.conf`** 的 **`RESOLUTION`** 为权威；执行 **`make sync-resolution`** 同步到 `config/desktop.conf` / `config/boot.conf`，与 ZBM GOP、`zig -Dzbm_preferred_fb_*` 对齐，避免「串口里 GOP 与嵌入配置宽高不一致」。

### 4.2.3 RISC-V64 UEFI：串口、QEMU 与「Guest has not initialized the display」

- **串口日志**：内核使用 **QEMU `virt` UART0 NS16550 MMIO `0x10000000`**（[`src/hal/riscv64/uart.zig`](../../src/hal/riscv64/uart.zig)），与 **`make run-riscv64`** 中 **`-serial stdio`** 一致；若 MMIO 发送超时则回退 **SBI legacy putchar（EID 0x01）**。UEFI 退出后若仅 SBI 不可用、又无 MMIO，会出现「全程无字符」；当前默认以 MMIO 为主路径缓解该问题。
- **极早诊断**：`kernel_main` 进入 [`startGeneric`](../../src/main.zig) 后、`boot.parse` 前会打印 **`HandoffDiag(rv):`**（magic、`a1`、`_uefi_vector.mb2_phys`）；解析后打印 **`BootHandoff(rv):`**（`mmap_entries`、`multiboot_fb`）。用于区分固件/ZBM 未跳内核、早期崩溃与 Multiboot2 解析失败。
- **早期异常**：[`src/arch/riscv64/start.S`](../../src/arch/riscv64/start.S) 提供 **`riscv_early_trap_entry`**，[`initSerial`](../../src/arch/riscv64/mod.zig) 将其写入 **`stvec`**；未覆盖完整 trap 帧前，异常时 UART 输出 **`>`** 并 **`wfi`** 循环，便于发现非法指令/缺页等。
- **QEMU 串口对照**（宿主机调试）：
  - 默认：`make run-riscv64`（`-serial stdio` + `-display gtk`）。
  - 仅串口、无 GTK：`qemu-system-riscv64 … -nographic`（需自行带上与 `Makefile` 相同的 `-bios`、磁盘、`QEMU_RISCV64_EXTRA` 等参数）。
  - 串口落盘：增加 **`-serial file:rv-serial.log`**（可与 **`-serial stdio`** 组合时使用 **`-serial mon:stdio`** 等，视 QEMU 版本而定；简单做法：复制 `Makefile` 中 `run-riscv64` 命令并将 **`-serial stdio`** 换成 **`-serial file:…`**）。
- **「Guest has not initialized the display (yet).」**：在客户机尚未通过 **ramfb 扫描输出**（guest 物理帧缓冲）或 **virtio-gpu 资源** 向 QEMU UI 提交像素时常驻；若**同时无串口日志**，优先按本节修串口与 handoff，再查 [`src/hal/riscv64/ramfb.zig`](../../src/hal/riscv64/ramfb.zig) 与桌面 **`pointRamfbToGuestPhys`**（[`src/main.zig`](../../src/main.zig) 与 AArch64 对称路径）。
- **ZBM 链路**：RISC-V 的 ZBM 为 **Zig 生成 `zbm_riscv64.o` + GNU-EFI（ncroxon）链接为 `BOOTRISCV64.EFI`**（`Makefile` **`build-zbm-riscv64-uefi`** / **`scripts/build/zbm-riscv64-efi.sh`**）。与 AArch64 共用 [`boot/zbm/uefi/main.zig`](../../boot/zbm/uefi/main.zig) 中 **UEFI 向量扫描、`mb2_phys` 写入、`kernel_main` 跳转**；内核侧为 [`src/arch/riscv64/start.S`](../../src/arch/riscv64/start.S) **`_uefi_vector` version 1（32 字节）**。

### 4.3 x86_64 手工验证预期（冒烟）

| 场景 | 预期 |
|------|------|
| 默认 `grab-on-hover=on` | 指针移入 GTK 窗口后捕获，REL/ABS 组合设备易见位移。 |
| `QEMU_GTK_EXTRA=`（关 grab 扩展） | REL 型 virtio-mouse 可能仍无位移；应依赖 **virtio-tablet** 的 ABS→像素映射或 `Ctrl+Alt+G` 手动抓取。 |
| 仅 `virtio-mouse-pci`（无 tablet） | 未抓取时可能仍不动；与 QEMU 行为一致，非内核单点故障。 |
| 仅 `virtio-tablet-pci` | 应有 ABS 映射位移（与当前 GOP 宽高一致）。 |

## 5. 桌面快捷键（壳层）

- **Ctrl+Shift+Esc**：任务管理器（x86：PS/2；VirtIO 键盘：`evdev_virtio_bridge`）。
- **Ctrl+Alt+F9**：循环 **Aero 壁纸预设**（与 `resource_loader` 内置壁纸条目顺序对应的程序化背景；非 SVG 光栅化）。

## 6. 颜色与主题单一源

- **DWM 数值**：`src/config/zircon_aero_defaults.zig`。
- **内核 `theme.rgb`**：`b | (g<<8) | (r<<16)`（Win32 COLORREF 风格）。
- **Aero 库 `desktop/aero/src/theme.zig` 的 `rgb`**：分量顺序相反，勿混用字面量。

## 7. 相关脚本与文档

### 7.1 指针流畅度：基线度量（`MOUSE_DEBUG`）

- **`hub_rounds`**：`input_hub.pollAll` 累计调用次数（每桌面 tick 内会远大于 1，因循环内多次 poll）。
- **`pops_last`**：当前桌面 tick 内 `mouse.popEvent` 次数；**高**表示队列里离散事件多，**低**且坐标仍跳变则多为合成/present 路径。
- 与 **`virtio inst` `used.idx`**、`syncDeliver total` 对照，可区分「环不前进 / deliver 少」与「事件多但 scene 全重绘」。
- **`render_full` / `render_drag` / `render_cap` / `render_fast`**（`desktop tick` 日志尾部累计计数）：分别为整场景、**拖窗合成**（`drag_layer`）、`renderer_aero.redrawCaptionBandsOnly`（标题栏三键热态）、纯光标 `moveOnly`。在标题栏上来回横扫时 **`render_cap` 应明显多于 `render_full`**；拖窗时 **`render_drag`** 递增而 **`render_full` 不应每帧暴涨**。
- 主循环 **`scene_dirty`** 由 `MouseMovePaintHint.needs_full_scene`（**不含**单纯拖窗位移）、UI 脏标记与插值驱动；**拖窗**使用 `needs_drag_repaint`；**标题栏悬停**使用 `needs_caption_chrome_only`。**开始菜单打开**且指针在菜单项间移动时仍为整场景（见 [PointerPolicy_NT61.md](PointerPolicy_NT61.md) D4 backlog）。
- **`caption_chrome_only` 与软件光标**：该路径在重绘标题栏带 **之前** 调用 `cursor_plane.restoreSaveUnderIfPlaced()` 恢复上一帧指针下的像素，再 `redrawCaptionBandsOnly()` → `composeAfterScene()`，并在末尾 `markMotionDirty(prev, new)` 把指针旧/新位置并入脏矩形，避免局部 `present` 漏擦轨迹。概念上与「离屏合成后再叠加指针」一致（公开说明见 [Desktop Window Manager](https://learn.microsoft.com/en-us/windows/win32/dwm/dwm-overview)）。
- **手工冒烟（x86_64 / LoongArch）**：标题栏三键横扫、地址栏↔标题栏斜移、打开开始菜单上下移动 — 对照上述三类计数与主观流畅度。

### 7.2 脚本与姊妹文档

- `make run-loongarch64-serial-debug` / `scripts/run_loongarch64_with_serial_debug_log.sh`：LoongArch QEMU 串口 **tee** 到终端并写入 **`.cursor/debug-80cc1c.log`**（`scripts/serial_dbg_to_cursor_log.py` 解析内核 **`DBG80cc1c`** 行）。**不要**使用裸命令 `make run-loongarch64 … \| python3 …`，否则 stdout 全进脚本，**终端无串口输出**。
- **`.cursor/debug-80cc1c.log` 判读（内核 ramfb 探针）**：由 `src/debug/session_ingest.zig` 经串口输出、脚本转为 NDJSON。**H1** `rb`/`cf` 的 **`u`** 为水平分辨率（如 1920）表示 **`setupWithDims` + fw_cfg 写 ramfb 成功**；**H2** `pf`/`fw` 的 **`u`=1** 表示 **`pointRamfbToGuestPhys` DMA 成功**；**H5** `pp`/`px0` 的 **`u` 非 0** 表示首帧 **`present` 后可见面首像素已写入**；**H3** `pp`/`rp1` 的 **`u`=1** 表示首帧后 **replay `pointRamfb` 成功**。若上述均成立而 **GTK 仍只见 UEFI 字**，则与 **内核首帧失败** 矛盾，应只查 **QEMU 多标签 / `-display` / `LOONGARCH64_QEMU_VIRTIO_GPU` / `GDK_BACKEND`**（见 §4.2.1.2、§4.2.1.1a）。
- `scripts/desktop-qa.sh`：内核构建 + Aero 库测试（建议加 `MOUSE_DEBUG=true` 做指针/VirtIO 对照）；可配合不同 GOP 分辨率、`display.double_buffer` 开关在配置中的组合做矩阵冒烟。
- `scripts/agent-ingest-serial.sh`：摄取 `AGENT_NDJSON` 日志。
- `docs/cn/DesktopQA.md`、`src/desktop/aero/resources/VISUAL_QA.md`：视觉与交互验收要点。
- `docs/cn/PointerPolicy_NT61.md`：注册表/控制面板语义与内核 `mouse.zig` 字段对照（clean-room，无抄码）。

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

- **配置**：`config` 中 `display.double_buffer` 为 `false` 时直接绘制屏前缓冲；为 `true` 时优先使用静态后备（≤10MiB 帧），更大则尝试 **`FrameAllocator.allocContiguous`** 申请连续物理页（须已在 `main` 中 `setKernelFrameAllocator`）。**其它键**（`src/config/desktop.conf`）：`triple_buffer`（乒乓第二离屏槽，默认关）、`present_full_flip`（双缓冲时默认整幅 `memcpy`；为 `false` 时用脏矩形 `flipDirty`，须保证光标区已 `mark dirty`）、`seed_gop_to_back`（初始化时把 GOP 拷入离屏槽，默认关）、`fall_back_single_on_alloc_fail`（超大帧堆分配失败时退化为单缓冲直写 GOP，默认开）。
- **单缓冲语义**：`double_buffer=false` 时 `getDrawBuffer()` 即 GOP；`flipDirty()` **不执行 memcpy**，仅清空脏矩形计数（绘制已在屏前完成）。
- **Present**：双缓冲且 `present_full_flip=true`（默认）时 `present()` 整幅提交；否则 `flipDirty()`。单缓冲下 `flipDirty` 仅清脏标记。
- **软件光标层**：实现集中在 **`src/drivers/video/cursor_plane.zig`**（save-under）；`display.renderDesktopFrameEx` 在场景合成之后调用。仅指针移动且壳层无脏时走快速路径；形态变化会回退整场景路径。`display.hardware_cursor` 仅为预留钩子（`notifyHardwareCursorIfAvailable`），仅接公开硬件文档路径，非 WDDM 专有 API。
- **诊断行**：进入桌面后串口有 **`DesktopPointerDiag:`**（`double_buf` / `triple_buf` / `virtio_input` / `ps2_hw` / `present_full_flip` 等），与 §3.1「坐标变 vs 画面不变」对照使用。
- **轻量多缓冲语义**：指针下的像素快照等价于 ideas.md 中「与主帧分离的叠加」的**软件实现**，非 WDDM/DXGI 的 Flip 链。

### 9.1 与 `mdcs/ideas.md`（硬件游标）的边界

`ideas.md` 描述 Windows 7 / WDDM 下 **显卡硬件 Cursor Sprite** 在扫描输出阶段叠加、与 DWM 合成解耦。本仓库内核路径为 **GOP/ramfb + 自绘合成**，无 `DxgkDdiSetPointerShape` 类接口；当前 **`display.notifyHardwareCursorIfAvailable`** 与配置项 **`display.hardware_cursor`** 仅为占位，便于将来接到真实显示迷你端口或固件提供的指针平面时再接硬件 sprite。**预期**：在 QEMU/无专用驱动时，指针始终走 **软件光标层**，延迟与桌面帧率一致；勿与 VirtIO-Input 事件路径混淆。

### 9.2 任务栏与 `ideas.md`（扫描输出前叠加）

Win7 参考模型中，任务栏与指针一样属于「提交到扫描输出前」的壳层元素。本内核中 **整幅由 `renderer_aero` 合成进帧缓冲**，任务栏由 **`display.renderDesktopAeroTaskbar`** 单一路径绘制（毛玻璃走 `dwm.renderGlassEffect` 的 `.taskbar` 分支，无 WDDM 提交队列）。这与 `ideas.md` 第二节「硬件叠加层」仅为**概念对照**：当前无独立扫描硬件层，一切为 CPU 绘制 + `present()`/`flip()`。

## 10. 最小复现建议（串口）

1. `make clean build MOUSE_DEBUG=true`（或 `AGENT_NDJSON=true`）  
2. `make run 2>&1 \| tee /tmp/zircon-serial.log`  
3. 在日志中搜索：`Input:`、`InputDiag:`、`DesktopPointerDiag:`、`FramebufferMem:`、`VirtIO-Input PCI`、`Desktop: fb`  
4. 若怀疑 HLT：`make run DESKTOP_IDLE_SPIN=true`  
5. 若遇 **`KERNEL PANIC: integer overflow`** 且需二分：`zig build … -Ddesktop_bisect=true`（或 Makefile 传入等价选项），查看最后一组 `desktop: pre/post renderDesktopFrameEx` 日志。

## 12. QEMU 桌面冒烟（按架构设备矩阵）

以下为 **最小人工冒烟**：确认串口出现桌面路径关键行，且 GTK/固件窗口可见或指针可动。详细设备变量见上文 **§4.1 各架构设备矩阵** 与根目录 `Makefile`。

| 架构 | 建议命令 | 串口应含（节选） |
|------|----------|------------------|
| **x86_64** | `make run` 或 `zig build` 后按 Makefile 的 QEMU 行 | `Framebuffer Driver:`、`user32: Screen synced`、`dwm.exe`、`Desktop: first frame presented` |
| **loongarch64** | `make run-loongarch64`（或等价 ESP + `qemu-system-loongarch64`） | 同上；另可有 `ramfb:` / `VM: LoongArch scanout FB` |
| **aarch64** | `make run-aarch64` | 依赖 ramfb/virtio 组合；至少 `VirtIO-Input PCI` 与 `Desktop: fb` 或回退说明 |
| **riscv64** | `make run-riscv64` | 同 AArch64，查 `HandoffDiag(rv)` 与 ramfb 日志 |

**指针**：在 QEMU 窗口内点击获得焦点后移动鼠标；若不动，按 **§3** 判据链与 `DESKTOP_IDLE_SPIN`、`virtio-mouse-pci` 逐项排查。

## 11. 版权与参考边界（clean-room）

- **允许**：根据 [Microsoft Learn](https://learn.microsoft.com/) / WDK 等**公开文档**理解 **行为与术语**（如 DWM 概念、GOP、输入设备类别）；本仓库实现为 **自研 Zig 代码**，与 Windows/ReactOS/Wine **源码**无衍生关系。
- **禁止**：复制或改写 Windows 泄露源码、ReactOS（GPL）、Wine（LGPL）等**第三方实现源码**；亦勿将外部文档镜像整段粘贴进本仓库作为「实现」。
- **第三方文档树**：若本地存在其它项目下的 `desktop-src` 类导出，仅可作**个人阅读**；本仓库以 **MS Learn 与硬件规范** 为白名单参考，不依赖闭源或违规渠道。
