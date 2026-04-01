# NT 6.1 公开文档契约矩阵（ZirconOSAero）

本表用于对照 **Microsoft Learn** 公开描述与仓库实现状态；实现须为 clean-room，禁止复制 Windows/ReactOS/Wine 源码。

**图例**：已实现 / 部分 / 未实现 — 以 `src/` 代码为准。

**验证**：阶段完成度须与 `zig build test`、`.github/workflows/ci.yml` 及 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) 中可复现步骤一致；禁止仅凭文档勾选「完成」。

## 0. 内核内存、虚拟内存与 SMP（基线）

| 能力 | 模块 | 状态说明 |
|------|------|----------|
| 物理帧位图 + mmap 过滤 | `src/mm/frame.zig` | 部分 — 见 [PHYS_ALLOC_AUDIT.md](PHYS_ALLOC_AUDIT.md) |
| 伙伴 + 连续物理页封装 | `buddy.zig` / `phys_buddy.zig` | 部分 — arena 接线随启动路径演进 |
| 通用堆 + 统计 / `heap_check` | `src/mm/heap.zig` | 部分 |
| Slab cache | `src/mm/slab.zig` | 部分 |
| VMA 槽位 + `mmFreeVirtualRange` | `src/mm/vm.zig` | 部分 |
| 用户指针探测 | `src/mm/probe.zig` | 部分 — syscall 路径逐步覆盖 |
| 进程页表释放（用户半区） | `arch/x86_64/paging.zig` `releaseUserHalfAddressSpace` | 部分 |
| 调度切换 CR3 | `src/ke/scheduler.zig` | 部分 |
| ACPI MADT / LAPIC 枚举 | `src/hal/x86_64/madt.zig` | 部分 |
| AP 入口 / TLB 广播占位 | `ap_entry.zig` / `tlb_broadcast.zig` | Stub |
| 每 CPU 调度与窃取 | `percpu_sched.zig` / `scheduler.zig` | 部分 — `home_cpu` 占位 |

### 0.1 x86_64 用户 / 内核布局（文档常量）

- 用户 canonical 上界：`vm.USER_VA_MAX_HINT_X86_64`（与 Intel SDM 一致）。
- 进程 PML4 **低 256 项**为用户子树；**高半区**内核映射与内核 `CR3` 指向的顶层表可共享同一套中间页表物理页 — 销毁进程时仅释放进程 **自有** PML4 页，且 `releaseUserHalfAddressSpace` **仅**递归释放索引 0..255 子树。

## 1. desktop-src 镜像（用户态与 Win32）

本地路径：`ZirconOSFluentRust/references/win32/desktop-src`（仅作离线目录索引，非许可声明）。

| 方向 | 建议子目录 | 仓库模块 | 说明 |
|------|------------|----------|------|
| 进程/线程 Native API | `ProcThread/` | `src/libs/ntdll.zig`, `src/ps/process.zig` | 对齐 MSDN 参数与 `PROCESSINFOCLASS` |
| 系统信息 | `SysInfo/` | `ntdll.zig`, `src/config/os_version.zig` | `NtQuerySystemInformation` 各 `SYSTEM_INFORMATION_CLASS` |
| 文件 I/O | `FileIO/` | `ntdll.zig`, `src/fs/vfs.zig` | 路径、`IO_STATUS_BLOCK` |
| GDI | `gdi/` | `src/subsystems/win32/gdi32.zig` | 与内核 win32k 无关，子系统行为 |
| DWM | `dwm/` | `src/desktop/aero/`, `docs/cn/DesktopManagerSpec.md` | 合成/脏区语义 |
| Shell / 命名空间 / 任务栏（概念与 UX） | `shell/`（如 `shell-namespace.md`, `taskbar.md`, `user-experience-guidelines.md`） | `src/drivers/video/renderer_aero.zig`, `shell_strings.zig`, `startmenu.zig` | 仅抽取术语与交互期望；实现独立，不抄文档示例代码 |
| 安全 | `SecAuthZ/` | `src/se/token.zig` | 令牌、模拟（长期） |

### 1.1 NT 6.1 优先阅读清单（离线镜像内路径）

按顺序浏览即可覆盖本仓库桌面/子系统主路径；**勿将文档中的示例 C++ 粘贴进实现**。

| 序号 | desktop-src 相对路径 | 公开文档主题（在线等价） |
|------|----------------------|---------------------------|
| 1 | `dwm/dwm-overview.md` | [Desktop Window Manager](https://learn.microsoft.com/windows/win32/learnwin32/the-desktop-window-manager) |
| 2 | `dwm/composition-ovw.md` | 合成开关、色键、非客户区策略 |
| 3 | `dwm/blur-ovw.md` | 毛玻璃 / Blur 概念 |
| 4 | `dwm/dwm-messages.md` | `WM_DWM*` 消息表 |
| 5 | `dwm/functions.md` / `dwm/enums.md` | `dwmapi` 子集与 Vista/7 常量 |
| 6 | `gdi/` 下与已实现 API 对应的参考页 | GDI 形参与返回值 |
| 7 | `ProcThread/`、`SysInfo/` | Native 线程/进程/系统信息类 |

### 1.2 故意不实现的较新 DWM / Win32 能力（避免向 Win10/11 漂移）

`desktop-src/dwm/toc.yml` 等索引中含 **Windows 8 以后** 才强调或专有的项。本仓库 ABI 目标为 **NT 6.1**，下列项**不计划**在兼容层中复刻完整语义（可保留占位或文档说明）：

| 能力 / API（概念名） | 说明 | 参考（Learn，只读行为） |
|----------------------|------|-------------------------|
| `DWM_SYSTEMBACKDROP_TYPE`、Mica / Acrylic 系统背景类型 | Win11 起桌面窗口背景模型 | [DWM_SYSTEMBACKDROP_TYPE](https://learn.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwm_systembackdrop_type) |
| `DwmAttachMilContent` / MIL 相关 | 与较新合成栈耦合 | desktop-src `dwm/toc.yml` 所列 |
| 始终开启的合成（Win8+ 行为） | Learn 注明 Win8 起合成始终启用，`WM_DWMCOMPOSITIONCHANGED` 可能不再发送 | [WM_DWMCOMPOSITIONCHANGED](https://learn.microsoft.com/windows/win32/winmsg/wm-dwmcompositionchanged) |

NT 6.1 上仍具参考意义的 **`DwmIsCompositionEnabled`、BlurBehind、ExtendFrame、缩略图 API** 等，以 `dwm/` 中 *Minimum supported client Windows Vista* 为边界。

## 2. WDK / 内核模式（desktop-src 不替代）

必读入口：<https://learn.microsoft.com/windows-hardware/drivers/>

| 主题 | 验收要点 | 仓库模块 |
|------|----------|----------|
| I/O Manager、IRP | Major/Minor、完成时状态与 `IoCompleteRequest` 语义 | `src/io/io.zig`, `src/fs/vfs.zig` |
| 设备对象与栈 | 设备扩展、附加栈（长期） | `io.zig` |
| PnP / Power | 即插即用与电源 IRP（长期） | 驱动目录 |
| IRQL、DPC | 同步级别约束（简化实现须在注释声明） | `src/ke/dpc.zig`, `interrupt_x86.zig` | 最小 DPC：输入轮询延后至 IRQ 出口 |
| 内存管理器 | 池标签、`Mdl`（长期） | `src/mm/` |

## 2.1 HAL / 总线与网络（阶段性）

| 主题 | 状态 | 仓库位置 / 说明 |
|------|------|------------------|
| ACPI RSDP（Multiboot2 tag 14/15）→ XSDT/RSDT → MCFG | 部分 | `src/boot/multiboot2_parse.zig`、`src/hal/x86_64/acpi_pci_early.zig`；无 AML 解释器 |
| PCIe ECAM MMIO `configRead32` | 部分 | 同上；启动时探测总线 0 设备 0 |
| USB XHCI / HID | 未 | 路线图：[HAL_USB_NET_ROADMAP.md](HAL_USB_NET_ROADMAP.md) |
| IPv4 / ARP / UDP 原型 | 未 | 路线图同上；TCP 非当前里程碑 |

## 3. 关键 Native API 与文档链接（示例）

| API | 参考（公开文档） | 备注 |
|-----|------------------|------|
| `NtQueryInformationProcess` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntqueryinformationprocess> | `ProcessInformationClass`、长度、`ReturnLength` |
| `NtQueryInformationThread` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntqueryinformationthread> | 同上 |
| `NtAllocateVirtualMemory` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntallocatevirtualmemory> | `MEM_*`、`PAGE_*` |
| `NtQuerySystemInformation` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntquerysysteminformation> | `STATUS_INVALID_INFO_CLASS` |
| `NtOpenKey` / `NtQueryValueKey` | WDK/Win32 注册表相关 | `OBJECT_ATTRIBUTES`、部分信息类 |
| `RtlNtStatusToWin32Error` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-rtlntstatustowin32error> | 与 `RtlNtStatusToDosError` 等价名 |

（随实现推进在 PR 中增删行并更新状态列。）

## 4. DWM 概念与内核/子系统实现对照（NT 6.1）

| 能力（文档概念 / API） | 状态 | 仓库位置 | 备注 |
|------------------------|------|----------|------|
| 离屏表面再合成 | 部分 | `renderer_aero.zig`, `dwm_compositor.zig`, `framebuffer.zig` | CPU 盒式模糊 + 预算：`nt61_aero_defaults.zig` |
| 合成启用查询（`DwmIsCompositionEnabled` 语义） | 部分 | `src/drivers/video/dwm.zig` | 内核策略位；无用户态 dwmapi DLL |
| `DwmEnableBlurBehindWindow` / 毛玻璃区域 | 部分 | `dwm.zig`, `material.zig`, `display.zig` | `renderGlassEffect` / `renderGlassTintOnly` |
| `DwmExtendFrameIntoClientArea` 策略 | 部分 | `display.zig`, `dwm_surface_spec.zig` | 标志与 NC/客户区绘制顺序 |
| `WM_DWMCOMPOSITIONCHANGED` | 部分 | `user32.zig`（`broadcastDwmCompositionChanged`） | 已向窗口队列投递；Shell 须在合成开关变化时调用 |
| `WM_DWMCOLORIZATIONCOLORCHANGED` | 部分 | `user32.zig`（`broadcastDwmColorizationChanged`） | 同上 |
| `WM_DWMNCRENDERINGCHANGED` | 部分 | `user32.zig`（`broadcastDwmNcRenderingChanged`） | 同上 |
| 缩略图 / `WM_DWMSENDICONICTHUMBNAIL` | 未 | `compositor.zig` 预留 | 可选 |
| GPU / WDDM 离屏纹理合成 | 未 | — | 长期项；当前为 CPU 帧缓冲路径（与 Win7 Aero 性能模型不同） |

## 5. user32 / gdi32 与 Learn 抽样核对（返回值约定）

以下为实现中**已出现**的入口与公开文档应对齐的要点（clean-room 手写，禁止粘贴示例代码）：

| API | 文档关注点 | 模块 |
|-----|------------|------|
| `CreateWindowEx` / `DestroyWindow` | 失败时 `NULL` 与 `SetLastError` | `user32.zig` |
| `GetMessage` / `PeekMessage` | 阻塞与非阻塞、`PM_*` | `user32.zig` |
| `BeginPaint` / `EndPaint` | `PAINTSTRUCT`、返回值 | `user32.zig` |
| `BitBlt` / `Rectangle` / `TextOut` | 成功非零、失败 0 | `gdi32.zig` |
| `CreateCompatibleDC` / `SelectObject` | 句柄与 STOCK 对象 | `gdi32.zig` |

完整列表随子系统扩展在 PR 中追加行。

## 6. 配置语义：`nt_product_arch` 与宿主 CPU

- **`system.nt_product_arch`**（嵌入 `system.conf`）：NT 6.1 **兼容层所宣称的产品处理器族**（如始终报告 `x86_64` 以匹配 WOW64/子集行为），**不等于** QEMU/固件实际 CPU。
- **宿主架构**：运行期以 `builtin.cpu.arch` 为准；`config.hostCpuArchName()` 与 `arch.impl.name` 用于串口/诊断。

## 7. 相关仓库文档

- [NT61_VirtualMemory_ABI_Notes.md](NT61_VirtualMemory_ABI_Notes.md) — `NtAllocateVirtualMemory` / `MEM_*` 与帧缓冲映射对照  
- [PROCESS_NT61.md](PROCESS_NT61.md) — 阶段与门禁  
- [ExecutivePhase3_Milestones.md](ExecutivePhase3_Milestones.md) — Phase 3 子里程碑  
- [SyscallABI.md](SyscallABI.md) — 本机 syscall 与 Windows SSDT 关系  
- [MM_Section_Roadmap.md](MM_Section_Roadmap.md) — 段对象与映射  
- [PointerPolicy_NT61.md](PointerPolicy_NT61.md) — 指针速度/加速与 `mouse.zig` 字段对照（桌面体验）  
