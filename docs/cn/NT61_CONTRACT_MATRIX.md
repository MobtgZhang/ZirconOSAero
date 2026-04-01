# NT 6.1 公开文档契约矩阵（ZirconOSAero）

本表用于对照 **Microsoft Learn** 公开描述与仓库实现状态；实现须为 clean-room，禁止复制 Windows/ReactOS/Wine 源码。

## 状态标签定义（与根 README 矩阵一致）

| 标签 | 含义 |
|------|------|
| **Done** | 主路径在 QEMU/CI 烟测下可演示，且与本表对应行描述一致；**不表示**与商业 Windows 7 内核等价。 |
| **Partial** | 子集实现或行为与文档仍有已知差距；见各「状态说明」列。 |
| **Stub** | 符号/结构存在，运行路径未实现或仅占位。 |
| **Planned** | 设计或路线图中有，代码未落地。 |
| **Verified** | 含主机单元测试或 CI 步骤的自动化回归（见 [MVT_NT61.md](MVT_NT61.md)）。 |

**图例**：已实现 / 部分 / 未实现 — 以 `src/` 代码为准。

**验证**：阶段完成度须与 `zig build test`、`.github/workflows/ci.yml`、[MVT_NT61.md](MVT_NT61.md) 及 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) 中可复现步骤一致；禁止仅凭文档勾选「完成」。

## Win32 兼容层：现实落差与项目边界

商业 Windows 上的 **Win32 / csrss / WOW64 / ntdll** 覆盖数百个 Native 与 Win32 入口，每个入口在参数探测、NTSTATUS、`SetLastError`、同步与对象生命周期上都有大量细节；**GDI**（BitBlt ROP、字体光栅化、设备上下文与句柄表）与 **csrss**（窗口站、桌面、会话、与内核 / LPC 的完整协议）同样是多年工程。

本仓库目标为：**在 clean-room 前提下（仅 Microsoft Learn、WDK、硬件规范及公开发表的 ABI 对照表），交付与 NT 6.1 **公开文档**可对齐、且可由 [MVT_NT61.md](MVT_NT61.md) / `tests/` 部分验证的子集**。不声称：

- 与 Windows 7 官方用户态 DLL **二进制兼容**或行为逐位等价；
- 已实现「完整」Win32、完整 SysWOW64、或完整 csrss 语义（这些与 [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) 中的延后项一致）。

对外表述须与 [API_COMPAT_MATRIX.md](API_COMPAT_MATRIX.md)、[docs/en/Subsystems.md](../en/Subsystems.md) 状态列同源；扩大兼容性须在 PR 中同步矩阵与测试。详见下文 **WOW64**、**csrss / LPC** 分节。

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

### 3.1 ntdll / SSDT 三向锚点（契约 ↔ 实现 ↔ 测试）

| 角色 | 路径 | 验证 |
|------|------|------|
| x64 公开服务号子集 | [`src/arch/x86_64/ssdt_nt61.zig`](../../src/arch/x86_64/ssdt_nt61.zig) | `zig build test` → **ssdt**（文内 Win7 SP1 参考断言） |
| 内核 syscall 分发与用户指针探测 | [`src/arch/x86_64/syscall.zig`](../../src/arch/x86_64/syscall.zig) | 分支配对；扩展时补 `tests/` |
| 用户态 `syscall` 薄层（与内核号一致） | [`src/sdk/ntdll_syscall_win64.zig`](../../src/sdk/ntdll_syscall_win64.zig) | **ssdt_stub_parity**（`Ssdt` 与 `ssdt_nt61` 同步子集） |
| 内核内联 / 桩 Native 调用 | [`src/libs/ntdll.zig`](../../src/libs/ntdll.zig) | 服务号须与 `ssdt_nt61` 一致；未实现路径返回文档化 NTSTATUS |

未在 `ssdt_nt61.zig` 列出的服务：分发器可返回 `STATUS_INVALID_PARAMETER` 等（见 [SyscallABI.md](SyscallABI.md)）；**不得**在文档中宣称「全量 Nt* 已完成」。

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

### 5.1 user32 / gdi32：非目标边界与分阶段交付

下列能力**不**作为当前里程碑的「完成」标准（可与 [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) 对照）；实现以 **Aero / 内置 Shell 所需最小子集** 优先，每扩展一类 API 须更新上表与本节。

| 领域 | 非目标 / 长期项 | 分阶段说明 |
|------|-----------------|------------|
| GDI BitBlt | 完整 ROP3、拉伸、颜色格式矩阵、与打印机 DC 的完整交互 | 当前为矩形/文本/位图子集；复杂 ROP 为 Planned |
| 字体 | ClearType/Uniscribe 级排版、完整 GDI 字体链接与回退 | 当前位图字体路径；FreeType 等为路线图项（见 API 矩阵 gdi32 行） |
| DC / 对象 | 完整 GDI 句柄表、跨进程 DC、元文件、路径 API | 以 `CreateCompatibleDC` / `SelectObject` 子集为主 |
| user32 消息 | 完整输入法、挂钩链、DDE、剪贴板全语义 | 消息泵与 DWM 广播等为 **Partial**；随契约矩阵增行 |

**user32**：优先保证 `GetMessage` / `PeekMessage`、`CreateWindowEx` 等与壳路径一致的入口；模态环与 NC 命中等为部分语义，须在 PR 中注明已知差距。

### 5.2 Shell / 脚本宿主（与 Microsoft PowerShell 的边界）

| 能力（文档概念） | 状态 | 说明 |
|------------------|------|------|
| **PowerShell** / cmdlet 脚本宿主 | **不适用（内核）** | 内核侧 **不实现** PowerShell 引擎；历史上 in-kernel ZirconShell 已移除。 |
| 用户态 **.NET** 脚本宿主（未来） | **Planned（仓库外）** | 与 PowerShell 公开 **行为与 cmdlet 模型** 对齐的宿主应在 **独立用户态程序 / 仓库** 实现；本仓库仅提供 Native / LPC / 对象等内核能力。 |
| 命令提示符（`cmd.exe` 语义子集） | Partial | `src/subsystems/win32/cmd.zig` 等；与上项正交。 |

## 6. 配置语义：`nt_product_arch` 与宿主 CPU

- **`system.nt_product_arch`**（嵌入 `system.conf`）：NT 6.1 **兼容层所宣称的产品处理器族**（如始终报告 `x86_64` 以匹配 WOW64/子集行为），**不等于** QEMU/固件实际 CPU。
- **宿主架构**：运行期以 `builtin.cpu.arch` 为准；`config.hostCpuArchName()` 与 `arch.impl.name` 用于串口/诊断。

## 7. 相关仓库文档

- [NT61_PR_GATES.md](NT61_PR_GATES.md) — **K0 PR 门禁勾选清单**（契约矩阵、MVT、syscall 注释、合规扫描）  
- [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) — **NT 6.1 内核模式分阶段待办（K0–K8）**与 clean-room 门禁；PR 与契约矩阵 §8 同步推进  
- [MVT_NT61.md](MVT_NT61.md) — 最小可验证测试索引（主机测试 + CI）  
- [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) — 不阻塞内核主里程碑的延后能力（WDDM / 完整 Win32 / WOW64 / AML 等）  
- [mdcs/composer2/content1.1.md](../../mdcs/composer2/content1.1.md) — 与 NT 6.1 目标之差距综述（与契约矩阵交叉引用）  
- [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) — LPC 与 csrss 握手 ABI（clean-room）  
- [NT61_VirtualMemory_ABI_Notes.md](NT61_VirtualMemory_ABI_Notes.md) — `NtAllocateVirtualMemory` / `MEM_*` 与帧缓冲映射对照  
- [PROCESS_NT61.md](PROCESS_NT61.md) — 阶段与门禁  
- [ExecutivePhase3_Milestones.md](ExecutivePhase3_Milestones.md) — Phase 3 子里程碑  
- [SyscallABI.md](SyscallABI.md) — 本机 syscall 与 Windows SSDT 关系  
- [MM_Section_Roadmap.md](MM_Section_Roadmap.md) — 段对象与映射  
- [PointerPolicy_NT61.md](PointerPolicy_NT61.md) — 指针速度/加速与 `mouse.zig` 字段对照（桌面体验）  

## 8. 内核路线图：契约条目 ↔ 代码路径 ↔ 自动化验证（三向跟踪）

PR 合并前将对应行更新为 **Partial / Done / Verified**；**Verified** 须指向具体测试目标或 CI 步骤名。

| 契约能力（与 §0–2 对应） | 主代码路径 | 测试 / CI |
|--------------------------|------------|-----------|
| 进程用户半区释放 + PML4 回收 | `src/mm/vm.zig` `releaseProcessAddressSpace`；`src/arch/x86_64/paging.zig` `releaseUserHalfAddressSpace` | 伙伴/连续帧：`src/mm/buddy.zig` 主机测试；内核路径见 [MVT_NT61.md](MVT_NT61.md) |
| 调度切换 CR3 | `src/ke/scheduler.zig` `activateCr3ForProcessId` | QEMU：`scripts/ci-qemu-smoke.sh` |
| 用户指针探测 | `src/mm/probe.zig`；`src/arch/x86_64/syscall.zig` | 各 syscall 分支配对；扩展时补 `tests/` |
| 每 CPU 就绪队列与工作窃取 | `src/ke/scheduler.zig`（32 级分桶 FIFO、`non_empty`、窃取）；`percpu_sched.zig` `assignCpuForNewThread`；亲和 `setThreadAffinityMask` | `zig build test` → **scheduler_policy_host**（公式）；QEMU 烟测 |
| TLB 一致性（SMP 前占位） | `src/hal/x86_64/tlb_broadcast.zig` | Debug 下多 CPU 时串口诊断；未来 IPI 用例 |
| LPC 端口种类 | `src/lpc/port.zig` `PortKind` | `zig build test` → **lpc_portkind_host**；[LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) |
| IRP 完成例程与栈下传 | `src/io/io.zig` `IoCompleteRequest`、`dispatchIrpThroughStack` | 主机：`tests/io_irp_host.zig`（完成例程 + 栈链镜像断言） |
| 对象路径规范化 | `src/ob/object.zig` `normalizeNtObjectPath` | `zig build test` → `object` |
| 合规短语扫描 | `scripts/verify-compliance.sh` | CI：`Compliance phrase scan (src/boot)` |
| `NtQuerySystemInformation` 子集 | `src/libs/ntdll.zig` | syscall + ntdll 一致性审查 |

**合规**：实现仅依据 MS Learn / WDK 公开描述与硬件规范；提交前运行 `bash scripts/verify-compliance.sh`。

## 9. KUSER_SHARED_DATA / TEB / Win32k 分流（加载微软 ntdll — 长期）

| 表面 | 公开依据 | 状态 |
|------|----------|------|
| `KUSER_SHARED_DATA` 用户映射页（时标、系统调用间隔等） | MSDN / WDK 概念 | **Planned** — 须固定用户 VA 并与 `syscall` 路径一致 |
| PEB / TEB 中线程与进程信息 | Learn — 进程线程 | **Partial** |
| Win32k 与 ntos SSDT 分流 | x64 上多表/MSR 行为（公开概述） | **Partial** — 本内核将部分用户消息 syscall 折叠进主 SSDT，见 [SyscallABI.md](SyscallABI.md) |
| 用户态 `Nt*` → `syscall` 薄层 | AMD64 调用约定 | **Partial** — [`src/sdk/ntdll_syscall_win64.zig`](../../src/sdk/ntdll_syscall_win64.zig)；内核内联桩仍为 `src/libs/ntdll.zig` |

### 9.1 WOW64：覆盖与已知缺口

| 项目 | 状态说明 | 代码 / 文档 |
|------|----------|-------------|
| x86（32 位）原生服务号 **公开子集**（与 x64 表不同号） | **Partial** — 对照 j00ru `x86/json/nt-per-system.json` Win7 SP1 | [`ssdt_x86_win7_sp1.zig`](../../src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig)；主机测试 **wow64_ssdt_x86**、**ssdt_x64_x86_namespace** |
| 64 位内核 SSDT 子集 | **Partial** | [`ssdt_nt61.zig`](../../src/arch/x86_64/ssdt_nt61.zig) |
| `translateSyscall32to64` | **演示 / 占位** — 当前 switch 使用与 x86 公开表 **不对齐** 的演示号；真实 SysWOW64 须走 64 位 SSDT + 独立映射 | [`wow64/thunk.zig`](../../src/subsystems/win32/wow64/thunk.zig)、[`wow64.zig`](../../src/subsystems/win32/wow64.zig) 文首注释、[SyscallABI.md](SyscallABI.md) |
| 32 位 PEB / TEB 布局 | **Partial** — `PEB32` / `TEB32` 结构与部分字段填充；非完整 NT 6.1 用户态布局验证 | [`wow64/types.zig`](../../src/subsystems/win32/wow64/types.zig) |
| 地址空间隔离 | **Partial** — WOW64 进程模型与栈/堆基址为简化演示 | `wow64.zig` |

### 9.2 csrss 风格子系统与 LPC 里程碑

| 阶段 | 内容 | 状态 |
|------|------|------|
| M1 | LPC 端口创建/连接、`PortKind` ABI 稳定；与 [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) 一致 | **Partial** — 见 `src/lpc/port.zig`、**lpc_portkind_host** |
| M2 | `subsystem.zig` 中进程注册、会话/窗口站/桌面 **数据结构** 与 CSR API 号枚举 | **Partial** — [`subsystem.zig`](../../src/subsystems/win32/subsystem.zig) `CsrApiNumber`、Desktop/WindowStation |
| M3 | 完整窗口站/桌面 **安全边界**、会话 0 隔离、与 LPC 大消息/节区视图握手的生产语义 | **Planned** — 握手占位见 LPC 文档 §与子系统 |
| M4 | 与真实 csrss 相当的进程生命周期、控制台/ GUI 分流、全消息泵协议 | **长期** — 见文首「现实落差」与延后表面文档 |

## 10. Clean-room 内核里程碑跟踪（与实现 PR 同步）

| 门禁 / 能力 | 说明 | 验证 |
|-------------|------|------|
| 合规短语扫描 | 禁止违规来源表述；`src/`、`boot/` 源扫描 | `bash scripts/verify-compliance.sh`；CI **Compliance phrase scan** |
| ECAM 偏移公式 | PCIe MCFG MMIO 布局与 `acpi_pci_early` 一致 | `zig build test` → **ecam_layout** |
| HPET GCAP_ID 解码 | IA-PC HPET 规范位域（无 MMIO 依赖） | `zig build test` → **hpet_id** |
| LPC `PortKind` 判别值 | csrss 握手 ABI 稳定 | `zig build test` → **lpc_portkind_host**；[LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) |
| IPv4 首部解析子集 | RFC 791 固定头（网络栈原型） | `zig build test` → **minimal_net** |
| MDL 最小子集 | WDK MDL 概念：VA/长度、内联 PFN 槽、恒等映射填 PFN 占位（无真实锁页 / 散列 DMA） | `zig build test` → **mdl_host**；[NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) K1.7 |
| IRP MJ PnP/Power 占位 | WDK 概念对齐的 major 序号 | `src/io/io.zig` `comptime` 断言；主机 **io_irp_host**（完成例程契约 + PnP/Power 序号） |
| VFS 访问掩码常量 | `FileAccessMode` 与 NT 风格 GENERIC 位一致 | `zig build test` → **fs_vfs_constants_host** |
| PCI 类/厂商 → 驱动绑定表（占位） | `src/drivers/bus/pci_driver_bind.zig`；供 USB/显示等枚举后选型 | `zig build test` → **pci_driver_bind_host** |
| SMP TLB 占位诊断 | 多逻辑 CPU 时 BSP 本地 flush 的串口提示 | Debug 构建 + `tlb_broadcast.requestGlobalFlushStub` |
