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

**验证**：须与 `zig build test`、CI、[MVT_NT61.md](MVT_NT61.md)、[REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) 一致；禁止仅凭文档勾选「完成」。**各文档职责**：[DOCS_MAINTAINERS.md](../DOCS_MAINTAINERS.md)。

## Win32 兼容层：现实落差与项目边界

商业 Windows 上的 **Win32 / csrss / WOW64 / ntdll** 覆盖数百个 Native 与 Win32 入口，每个入口在参数探测、NTSTATUS、`SetLastError`、同步与对象生命周期上都有大量细节；**GDI**（BitBlt ROP、字体光栅化、设备上下文与句柄表）与 **csrss**（窗口站、桌面、会话、与内核 / LPC 的完整协议）同样是多年工程。

本仓库目标为：**在 clean-room 前提下（仅 Microsoft Learn、WDK、硬件规范及公开发表的 ABI 对照表），交付与 NT 6.1 **公开文档**可对齐、且可由 [MVT_NT61.md](MVT_NT61.md) / `tests/` 部分验证的子集**。**阶段 4** 起对 **已实现子集** 强化 **ABI 锚点**：[`dwm_nt61_abi_inventory.zig`](../../src/config/dwm_nt61_abi_inventory.zig)（`dwmapi` 导出名表）、[`nt61_core_dll_abi_inventory.zig`](../../src/config/nt61_core_dll_abi_inventory.zig)（`ntdll`/`kernel32`/`user32` 合成导出顺序）、[`CORE_DLL_PE_EXPORT_STRATEGY.md`](CORE_DLL_PE_EXPORT_STRATEGY.md)、[`DWMAPI_PE_EXPORT_STRATEGY.md`](DWMAPI_PE_EXPORT_STRATEGY.md)、[`dwmapi_wow64.zig`](../../src/subsystems/win32/dwmapi_wow64.zig)（PE32 布局）、主机 **`dwm_nt61_abi_inventory_host`** / **`nt61_core_dll_abi_inventory_host`** / **`dwmapi_wow64_host`**；仍**不**声称在商业 Windows 上可替换微软同名系统 DLL 或与之逐位行为等价。不声称：

- 与 Windows 7 官方用户态 DLL 在任意环境下的 **全面二进制兼容**或行为逐位等价；
- 已实现「完整」Win32、完整 SysWOW64、或完整 csrss 语义（这些与 [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) 中的延后项一致）。

对外表述须与 [API_COMPAT_MATRIX.md](API_COMPAT_MATRIX.md)、[docs/en/Subsystems.md](../en/Subsystems.md) 状态列同源；扩大兼容性须在 PR 中同步矩阵与测试。详见下文 **WOW64**、**csrss / LPC** 分节。

## 0. 内核内存、虚拟内存与 SMP（基线）

| 能力 | 模块 | 状态说明 |
|------|------|----------|
| 物理帧位图 + mmap 过滤 | `src/mm/frame.zig` | 部分 — 见 [PHYS_ALLOC_AUDIT.md](PHYS_ALLOC_AUDIT.md) |
| 伙伴 + 连续物理页封装 | `buddy.zig` / `phys_buddy.zig` | 部分 — `main.zig` 启动 `initKernelContiguousBuddy`；主机仅 `buddy` 单测（`phys_buddy` + `frame` 联合受模块根限制） |
| 通用堆 + 统计 / `heap_check` | `src/mm/heap.zig` | 部分 |
| Ex 池路径 + IRQL + 分配全景 | `src/mm/ex_pool.zig`、`docs/cn/MM_ALLOC_PATHS.md` | 部分 — **Verified**（主机 `pool` / 注释）；Paged **软上限** `setPagedPoolSoftLimitForTest` |
| Slab cache | `src/mm/slab.zig` | 部分 |
| VMA 槽位 + `mmFreeVirtualRange` | `src/mm/vm.zig` | 部分 |
| fork 子集：用户 4Ki 叶 dup + `notePageShared` + 子侧只读 PTE + `#PF` CoW | `vm.zig` / `paging.zig` / `frame.zig` | 部分 — 大页未展开；节区 `PAGE_WRITECOPY`、页文件、Standby/Modified、每 `mapPage` 级全局 PFN 引用仍为延后；主机 **fork_cow_share_nt61_host**（Verified） |
| 用户指针探测 | `src/mm/probe.zig` | 部分 — `syscall*.zig` 已覆盖主路径；K1.5 以契约矩阵 + 代码审查为闸门 |
| 进程页表释放（用户半区） | `arch/x86_64/paging.zig` `releaseUserHalfAddressSpace` | 部分 — `vm.releaseProcessAddressSpace` 前递增 TLB shootdown 提示（`tlb_broadcast`） |
| 调度切换 CR3 | `src/ke/scheduler.zig` | 部分 — tick 路径 `activateCr3ForProcessId`；`terminateProcess` 前经 `before_release_process_address_space` 拆除该 pid 的调度线程（K2.1） |
| ACPI MADT / LAPIC / 首 IOAPIC 基址枚举 | `src/hal/x86_64/madt.zig` | 部分 |
| AP 入口 / TLB 广播占位 | `ap_entry.zig` / `tlb_broadcast.zig` / `smp_boot.zig` / `lapic_smp.zig` / `interrupt_x86.zig` / `idt.zig` | 部分 — 多核时 **INIT + SIPI×2**，实模式自旋跳板 phys **`0x8000`**；**IDT 向量 254** = TLB flush IPI 处理（`flushLocal` + `sendLocalEoi`）；**`-Dsmp_tlb_ipi`** 控制是否广播；**`-Dlapic_periodic_tick`** 可选 LAPIC LVT tick（见 [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) K2.4/K2.5） |
| 每 CPU 调度与窃取 | `percpu_sched.zig` / `scheduler.zig` | 部分 — 新线程 `home_cpu` 由最短就绪队列选取（`pickBalancedHomeCpu`）；窃取与 **AP 未实跑 tick**（仅 BSP） |
| 单调时钟 / HPET 只读 | `ke/timekeeping.zig` / `hal/x86_64/hpet.zig` | 部分 — HPET MMIO 探测与主计数器；IRQ0 仍为 PIT |
| 内核 #PF 结构化 STOP | `src/ke/bugcheck.zig`、`src/ke/interrupt_x86.zig` | 部分 — `keBugCheckEx` + `PAGE_FAULT_IN_NONPAGED_AREA` 等价码；用户态仍走 lazy/CoW 或终止进程 |
| 节对象句柄末引用回收 | `src/mm/section.zig`、`src/ob/cleanup_hooks.zig`、`src/ob/object.zig` | 部分 — `ref_count==0` 回收 `g_sections`；**映射仍存时关句柄** 为差距 |
| SEC_IMAGE / 节头布局锚点 | `src/loader/pe.zig`、`sdk/pe64_nt61.zig` | 部分 — `SEC_IMAGE` 常量 + `SectionHeader` 40 字节 `comptime` 测（`pe64_nt61_host` / 内核 `pe` 内测） |

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
| Shell / 命名空间 / 任务栏（概念与 UX） | `shell/`（如 `shell-namespace.md`, `taskbar.md`, `user-experience-guidelines.md`） | `src/drivers/video/desktop/renderer_aero.zig`, `shell_strings.zig`, `startmenu.zig` | 仅抽取术语与交互期望；实现独立，不抄文档示例代码 |
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
| I/O Manager、IRP | Major/Minor、`NTSTATUS` 完成码、双层完成例程、`IoCallDriver`/`dispatchIrpThroughStack`、卷设备扩展 | `src/io/io.zig`, `src/fs/vfs.zig`；主机验证 `zig build test` → **io_irp_host** |
| 设备对象与栈 | 设备扩展、附加栈（长期） | `io.zig` |
| PnP / Power | 即插即用与电源 IRP（长期） | 驱动目录 |
| IRQL、DPC、APC、等待 | 同步级别约束（简化须在注释声明）；**IRQL/DPC 每 CPU 槽**（`MAX_IRQL_CPUS`，默认 BSP）；**等待（阶段 C）**：`ObjectHeader` FIFO 等待队列 + `ke/wait` 与 `blockThread`/`tick` 协同；`NtWaitForSingleObject` / WaitAny（≤64）+ **tick 超时** + **alertable**（`NtAlertThread` → `STATUS_ALERTED`，用户 APC → `STATUS_USER_APC`）；**WaitAll**：**抢占调度关** 时协作式子集；**调度开** 仍为 `STATUS_NOT_IMPLEMENTED`；**事件** 手动/自动复位与 `NtSetEvent`/`onEventSet` 一致。非完整 CR8/设备 IRQL 谱系；用户 APC **例程交付** 仍为 Partial | `ob/object.zig`（`WaitEntry`）、`ke/irql.zig`、`ke/dpc.zig`、`ke/apc.zig`、`ke/wait.zig`、`ke/scheduler.zig`、`interrupt_x86.zig`、`syscall.zig`（返用户前 `deliverKernelApcsForCurrentThread`） |
| 内存管理器 | 池标签、`Mdl`（长期） | `src/mm/` |

## 2.1 HAL / 总线与网络（阶段性）

| 主题 | 状态 | 仓库位置 / 说明 |
|------|------|------------------|
| ACPI RSDP（Multiboot2 tag 14/15）→ XSDT/RSDT → MCFG/FACP/HPET/MADT | 部分 | `acpi_core.zig`（RSDP/表头校验和、分发）、`acpi_pci_early.zig`（ECAM）、`acpi_tables_parse.zig`（主机黄金测）；DSDT 指针仅记录；无 AML 解释器 |
| PCIe ECAM MMIO `configRead32` | 部分 | 同上；启动时探测总线 0 设备 0 |
| USB XHCI / HID | 未 | 路线图：[HAL_USB_NET_ROADMAP.md](HAL_USB_NET_ROADMAP.md) |
| IPv4 / ARP / UDP 原型 | 部分 | `minimal_stack.zig`：IPv4 固定头 + ARP 首部 8 字节解析；收发与 TCP 仍为路线图 |

## 3. 关键 Native API 与文档链接（示例）

| API | 参考（公开文档） | 备注 |
|-----|------------------|------|
| `NtQueryInformationProcess` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntqueryinformationprocess> | `ProcessInformationClass`、长度、`ReturnLength` |
| `NtQueryInformationThread` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntqueryinformationthread> | 同上 |
| `NtAllocateVirtualMemory` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntallocatevirtualmemory> | `MEM_*`、`PAGE_*` |
| `NtProtectVirtualMemory` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntprotectvirtualmemory> | SSDT `0x4D`（Win7 SP1 x64）；`syscall.zig` → `ntdll.zig` → `vm.protectVirtualRange` / `paging.protectLeafPage` |
| `NtDelayExecution` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntdelayexecution> | SSDT `0x31`；**负**间隔以 `scheduler.yield` 粗近似；**正**间隔（NT 绝对 `LARGE_INTEGER`）当前无单调域换算 → 立即 `SUCCESS` 且不睡眠（见 [PHASE_E_NATIVE_API.md](PHASE_E_NATIVE_API.md)、[TimerPrecisionRoadmap.md](TimerPrecisionRoadmap.md)） |
| `NtQuerySystemInformation` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntquerysysteminformation> | **Partial** — `SystemBasicInformation` / `SystemProcessorInformation` / `SystemVersionInformation` / `SystemTimeOfDayInformation`（48B 零）/ `SystemProcessInformation`（96B 单进程桩）/ `SystemPerformanceInformation`（128B 零前缀）/ **阶段 E** `SystemInterruptInformation`（32B 零）、`SystemExceptionInformation`（16B 零）；`SystemModuleInformation`/`SystemPoolTagInformation`/`SystemHandleInformation` → `NOT_IMPLEMENTED`；未列 class → `INVALID_INFO_CLASS`；`NtSetSystemInformation` → `NOT_IMPLEMENTED` 或非法 class |
| `NtOpenKey` / `NtOpenKeyEx` / `NtQueryValueKey` / `NtCreateKey` / `NtSetValueKey` / `NtEnumerateKey` / `NtEnumerateValueKey` | WDK/Win32 注册表相关 | `NtOpenKey` `0x0F`；`NtOpenKeyEx`：`options==0` 等价 `NtOpenKey`，非零事务类 → `STATUS_NOT_IMPLEMENTED`；其余键 API 同上 |
| `RtlNtStatusToWin32Error` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-rtlntstatustowin32error> | 与 `RtlNtStatusToDosError` 等价名 |
| `RtlGetVersion` | <https://learn.microsoft.com/windows/win32/sysinfo/nf-sysinfo-rtlgetversion> | 与 [`os_version.zig`](../../src/config/os_version.zig) 单源一致 |
| `RtlVerifyVersionInfo` | <https://learn.microsoft.com/windows/win32/devnotes/rtlverifyversioninfo> | **Partial** — `VER_EQUAL` / `VER_GREATER_EQUAL` 等条件子集；`verSetConditionMask` 与比较逻辑在 `os_version.zig`；`ntdll.zig` 包装；主机 **rtl_verify_version_info_host** |
| `NtCreateProcess` | Winternl | SSDT **0x9F**（j00ru Win7 SP1 x64）；`syscall_nt_extras` → `ntdll.NtCreateProcess`（仅分配进程槽；**无** 映像线程，与 `NtCreateUserProcess` 区分） |
| `NtCreateUserProcess` | Winternl | SSDT **0xAA**；**Partial** — ZOA 参数块、`NtCreateUserProcessFromPath`、PE 桩 + 调度线程；差距见 [PHASE_F_PROCESS_CREATE.md](PHASE_F_PROCESS_CREATE.md) |
| `NtSetInformationObject` | Winternl | SSDT **0x56**（本仓库专用槽，公开 0x59 与 `NtUserPeekMessage` 冲突）；`STATUS_NOT_IMPLEMENTED` / `INVALID_INFO_CLASS` |
| `NtSignalAndWaitForSingleObject` | Winternl | SSDT **0x176**；`NtSetEvent` + `NtWaitForSingleObject` 组合 |
| `NtReadFile` / `NtWriteFile` | <https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-readfile>（行为级对应 Native 层） | x64 syscall 分发：`syscall_nt_extras.zig` → `ntdll.zig` → VFS/IRP |
| `NtDeviceIoControlFile` | Learn / WDK IOCTL | SSDT **0x52**（与公开表 `0x07` 冲突的折叠槽，见 SyscallABI）；子集：`IOCTL_RTC_GET_TIME`（x86_64 + RTC 已初始化） |
| `NtLockVirtualMemory` / `NtUnlockVirtualMemory` | Learn | SSDT **0x53 / 0x54**；成功桩，见 [NT61_VirtualMemory_ABI_Notes.md](NT61_VirtualMemory_ABI_Notes.md) |
| `NtQueryDirectoryFile` | <https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-getfileinformationbyhandleex> 概念层；本内核 `FileNamesInformation` 单条 | `ntdll.zig` + 目录 `FileObject` |
| `NtDuplicateObject` | <https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntduplicateobject> | 同进程句柄表：`ntdll.zig`；SSDT `0x44`（Win7 SP1 x64 公开表） |
| `NtRequestWaitReplyPort` / `NtReplyWaitReceivePort` | WDK — LPC 端口消息 | 客户端：`requestWaitReplyPort`；服务端：`port.replyWaitReceivePort` ↔ `ntdll.NtReplyWaitReceivePort` |
| `NtWaitForSingleObject` | <https://learn.microsoft.com/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject>（用户态包装；Native 语义见 Winternl） | `ke/wait.zig`：事件 + **互斥/信号量**（静态池、`creation_time` 打包信号量计数）+ 超时 + `alertable`；经 `ntdll` / syscall 分发 |
| `NtWaitForMultipleObjects` | Winternl / synchapi 概念层 | **WaitAny** 子集（`count ≤ 64`）；SSDT **0x57**；**WaitAll**（`wait_type==1`）：协作式（调度关）；**调度开** → `STATUS_NOT_IMPLEMENTED`（见 [PHASE_E_NATIVE_API.md](PHASE_E_NATIVE_API.md)） |

（随实现推进在 PR 中增删行并更新状态列。）

### 3.1 ntdll / SSDT 三向锚点（契约 ↔ 实现 ↔ 测试）

| 角色 | 路径 | 验证 |
|------|------|------|
| x64 公开服务号子集 | [`src/arch/x86_64/ssdt_nt61.zig`](../../src/arch/x86_64/ssdt_nt61.zig) | `zig build test` → **ssdt**（文内 Win7 SP1 参考断言） |
| 内核 syscall 分发与用户指针探测 | [`src/arch/x86_64/syscall.zig`](../../src/arch/x86_64/syscall.zig)、[`syscall_nt_extras.zig`](../../src/arch/x86_64/syscall_nt_extras.zig) | **阶段 B** + **阶段 F 子集**：`NtCreateUserProcess`（**0xAA**）→ `dispatchNtCreateUserProcess` + `ZirconCreateUserProcessArgs`（见 [PHASE_F_PROCESS_CREATE.md](PHASE_F_PROCESS_CREATE.md)）；ALPC 等仍为 `STATUS_NOT_IMPLEMENTED` |
| 用户态 `syscall` 薄层（与内核号一致） | [`src/sdk/ntdll_syscall_win64.zig`](../../src/sdk/ntdll_syscall_win64.zig) | **ssdt_stub_parity**（`Ssdt` 与 `ssdt_nt61` 同步子集） |
| 内核内联 / 桩 Native 调用 | [`src/libs/ntdll.zig`](../../src/libs/ntdll.zig) | 服务号须与 `ssdt_nt61` 一致；未实现路径返回文档化 NTSTATUS |

未在 `ssdt_nt61.zig` 列出的服务：分发器可返回 `STATUS_INVALID_PARAMETER` 等（见 [SyscallABI.md](SyscallABI.md)）；**不得**在文档中宣称「全量 Nt* 已完成」。

## 4. DWM 概念与内核/子系统实现对照（NT 6.1）

| 能力（文档概念 / API） | 状态 | 仓库位置 | 备注 |
|------------------------|------|----------|------|
| 离屏表面再合成 | 部分 | `renderer_aero.zig`, `dwm_compositor.zig`, `framebuffer.zig` | CPU 盒式模糊 + 预算：`nt61_aero_defaults.zig` |
| 合成启用查询（`DwmIsCompositionEnabled` 语义） | 部分 | `src/drivers/video/core/dwm.zig` | `composition_enabled` 与 `glass_enabled` 分离；`isEnabled()` 随合成位 |
| `DwmEnableBlurBehindWindow` / 毛玻璃区域 | 部分 | `dwm.zig`, `material.zig`, `display.zig` | `renderGlassEffect` / `renderGlassTintOnly` |
| `DwmExtendFrameIntoClientArea` 策略 | 部分 | `display.zig`, `dwm_surface_spec.zig` | 标志与 NC/客户区绘制顺序 |
| `WM_DWMCOMPOSITIONCHANGED` | 部分 / 规则 Verified | `user32.zig`（`broadcastDwmCompositionChanged`） | 仅随 `dwm.setCompositionEnabled`；毛玻璃走 `setGlass` + `WM_DWMNCRENDERINGCHANGED` |
| `WM_DWMCOLORIZATIONCOLORCHANGED` | 部分 / 规则 Verified | `user32.zig`（`broadcastDwmColorizationChanged`） | `setColorizationTint`；**及** `dwm.syncPolicyFromRegistry` 在 **已有 HWND** 且染色 dword 相对变化时（`dwm_config_registry_sync`） |
| `WM_DWMNCRENDERINGCHANGED` | 部分 / 规则 Verified | `user32.zig`（`broadcastDwmNcRenderingChanged`） | `setGlass`；**及** `syncPolicyFromRegistry` 在 **已有 HWND** 且不透明度 / 任务栏染色 / Peek 相对变化时 |
| 缩略图 / `WM_DWMSENDICONICTHUMBNAIL` | 部分 / 规则 Verified | 每表面 `dwm_compositor` 缓冲 + `user32.broadcastDwmIconicThumbnailRequested`（`max_w/max_h` 钳位 `0xFFFF`）；`enqueueIconicThumbnailRequest` 拒无效 `surface_id`；零宽/零高表面不刷新缩略；**同 `thumb_refresh_min_ticks` 节流**（与 `notifyFramePresented` 路径一致） | 节流：`thumb_refresh_min_ticks`（`initAeroDwm` 按 tick_hz 换算 ≈120ms）；主机 **dwm_nt61_integration_host** |
| Live Preview / `WM_DWMSENDICONICLIVEPREVIEWBITMAP` | 部分 / 规则 Verified | `user32.broadcastDwmIconicLivePreviewBitmapRequested` 与 iconic 相同 `lParam` 打包；任务栏 Explorer 磁贴悬停采样路径与 iconic 同步广播 | 主机 **dwm_nt61_integration_host** |
| GPU / WDDM 离屏纹理合成 | 未 | `display_backend.zig`（`gop_linear` / `virtio_scanout` 观测）、`wddm_abstraction.zig` | 长期项；**非** IOCTL 级 WDDM；VirtIO 2D scanout 为呈现台阶（与 Win7 Aero 性能模型不同） |

### 4.1 DWM / 桌面壳层 backlog（与实现 PR 同步）

| 条目 | 状态 | 说明 |
|------|------|------|
| 内核 `KernelCompositorSurfaceFlags` ↔ 用户态 `SurfaceFlags` 语义映射 | **Verified**（主机 **aero_flag_mapping_host**） | [aero_flag_mapping.zig](../../src/config/aero_flag_mapping.zig)；桌面 `compositor.zig` `comptime` 布局锁 |
| 颜色 COLORREF ↔ 内核 `theme.rgb` | **Partial / 规则 Verified** | [color_nt61.zig](../../src/config/color_nt61.zig)：`KernelBgr888Low24` / `ColorrefLow24` 语义别名；`comptime` 往返；**BGR 低 24 与 COLORREF 同 RGB 三元组下数值必不等**（主机 **color_nt61_host**）；跨界须经本模块；`dwm.syncPolicyFromRegistry` 经转换后若 HWND 已存在则补发 `WM_DWMCOLORIZATIONCOLORCHANGED`（见 [DWM_NOTIFY_MODEL_NT61.md](DWM_NOTIFY_MODEL_NT61.md)） |
| 装饰性铬色 `rgb(...)`（非 DWM 染色契约） | **允许（矩阵登记例外）** | `dwm.zig` 标题栏/任务栏铬线、`startmenu.zig` 内层面板 tint、`display.renderHarmonyStyleWallpaper` 壁纸渐变等；**权威 DWM 玻璃染色 dword** 仍以 `nt61_aero_defaults` + `color_nt61` + `setColorizationTint` / 注册表为准 |
| 用户态 `flip3d_preview_enabled` ↔ 内核 Flip3D | **Partial（语义对照 + 文档化桥接约定）** | 内核不链接用户态 `compositor.zig`；**宿主桥接**时应在获知 `flip3d_overlay_active` 后调用 `setFlip3dPreviewEnabled`（见 `compositor.zig` 文档注释）。二者均为 **CPU 预览**，非 WDDM Flip3D |
| HWND ↔ `RedirectedSurface` / csrss `register_window` | **Partial / 子集 Verified** | **Verified 子集（可主机/串口锚点）**：(1) `CreateWindowEx` ↔ **`refreshGuiWindowCompositorAndTables`**（与 `ensureCompositorSurface` 同路径）；(2) `DestroyWindow` ↔ `detachCompositorSurface`；(3) LPC `register_window` ↔ `onCsrssRegisterGuiWindow`（同上单函数）；(4) **Shell 内联** `display.zig` 对 Explorer/任务管理器 `createSurface` 为壳层占位，**不**经 `user32` HWND 表；(5) `SetWindowPos`：`HWND_TOPMOST` / `HWND_NOTOPMOST` 维护 `Window.is_topmost` 并与 **`syncCompositorZOrderForUserWindows` 两趟序**一致；**Learn**：`HWND_NOTOPMOST` 在窗口**已非** topmost 时 **不**调整 Z 序；`HWND_TOP` / `HWND_BOTTOM` 仅在 **同 band** 内调整；**另一有效 HWND 之后**：跨 band 对齐 `is_topmost` 后插入（`placeHwndAboveInsertAfter`；主机 **`dwm_zorder_nt61_host`**）；(6) `hWndInsertAfter==0` 且未置 `SWP_NOZORDER` 时不改 Z 序数组顺序（位置/尺寸仍更新）；`SWP_FRAMECHANGED` 等重绘位当前忽略。LPC `get_message`：**线程 id 不得为 0**（`csr_lpc_policy.resolveGetMessageClientTid`）；GUI LPC 经 **`seAccessActiveDesktopForWin32k`**（当前占位 `createUserToken`）与活动桌面一致。**非 Verified**：跨进程 HWND、CSRSS 独立建窗。见 [DesktopManagerSpec.md](DesktopManagerSpec.md) §3.4–§3.5；主机 **`dwm_nt61_integration_host`**、**`dwm_zorder_nt61_host`**、**`csr_lpc_policy_host`**、**`nt61_dual_track_host`** |
| 方案 A：Present 脏区 / 帧节拍 API | **Partial** | `display.submitCompositorPresentHints`、`getPresentTelemetry`、`getDesktopComposeTelemetry`；[DesktopManagerSpec.md](DesktopManagerSpec.md) §1.1 |
| 多监视器 / DPI（单 GOP 扩展点） | **Partial** | `framebuffer.MonitorLayoutNt61`、`getVirtualDesktopBounds`、`physicalToLogicalPx`；`display.getDesktopMonitorLayout*`；主机 **multimon_dpi_nt61_host** |
| Aero Peek 竖条命中（Shell） | **Partial** | `taskbar.isClickOnShowDesktopPeek` / `setAeroPeekActive`；主机 **taskbar_peek_hit_nt61_host** |
| CPU 盒式模糊预算（`w×h×passes`） | **Verified（公式）/ Partial（帧级观测）** | [dwm_blur_budget.zig](../../src/config/dwm_blur_budget.zig) 与 `dwm.tryConsumeBlurBudget` 同源；**`zig build test` → dwm_blur_budget_host**；`-Ddwm_blur_stats=true` 每帧 `klog.debug` 统计（见 [SOFTWARE_COMPOSITOR_WDDM.md](SOFTWARE_COMPOSITOR_WDDM.md)） |
| `WM_DWM*` 广播 + 线程监听 `register_dwm_listener` | **Partial（有 HWND 才泵注册表差异；监听表在 csr 侧；LPC v1 载荷）** | `csr_dwm_listeners.zig` + LPC `0x10027`（**v1** 魔数 `0x014D5744` + tid@4，见 [`LPC_NT61_HANDSHAKE.md`](LPC_NT61_HANDSHAKE.md)、`csr_lpc_policy`）+ 内核 `registerDwmNotificationListener` 同表；`user32.broadcastDwm*`（`dwm_nt61_api_contract` 打包器）；**`dwm_messages_nt61_host`** / **`csr_lpc_policy_host`** / **`dwm_nt61_integration_host`** / **`dwm_config_registry_sync_host`** |
| Flip3D（Alt+Tab）CPU 近似 | **Partial / 规则 Verified** | **Alt+Tab**：首次打开覆盖层，再次 **轮转** `flip3d_shell_tab_index`（底栏 shell 卡高亮）；**Esc**（非 Ctrl+Shift+Esc）**`consumeFlip3dDismiss`** 关闭。`flip3d_needs_scene_refresh` + `collectShellWindowSurfaceIds`：**缓冲** `flip3d_shell_sid_buffer_cap=6`、**最多绘制** `flip3d_shell_thumb_paint_max=4`；过滤同矩阵前文。热键 **`consumeFlip3dHotkey`** 仅在 `display.handleDesktopHotkeys` 消费；[DesktopManagerSpec.md](DesktopManagerSpec.md) §8；主机 **dwm_zorder_nt61_host**、**win32k_api_semantics_host** |
| 开始菜单悬停局部重绘 | **Partial / 子集 Verified** | `handleMouseMove`：**不**将菜单行悬停升为 `needs_full_scene`；走 `needs_startmenu_repaint` → `startmenu_partial`（嵌入壁纸 `presetSupportsPartialRedraw` 时）。`redrawStartMenuRegionOnly` + 行级脏区；搜索 **50ms** 节流（`startmenu.zig`）；**主机** **startmenu_paint_hint_nt61_host**；`-Ddesktop_bisect` + `mouse_debug` 看 `startmenu_partial` |
| `DwmRegisterThumbnail` / `DwmUpdateThumbnailProperties` 像素合成 | **Partial** | `dwm_compositor` 槽位 + `display.blitRegisteredDwmThumbnailsToFramebuffer`：`DWM_TNP_VISIBLE`+`DWM_TNP_RECTDESTINATION` 时将源 HWND 表面缩略缓冲 **最近邻缩放** 到目标矩形；`GetWindowRect`+`rcDestination` 为 **Learn 客户区坐标** 的 **Partial** 近似；`DWM_TNP_OPACITY` 子集 |
| VirtIO-GPU 2D / scanout | **Partial** | **SET_SCANOUT**：`RESOURCE_ATTACH_BACKING` **单段或** 按页多段 mem_entry + `display.present` 后 `RESOURCE_FLUSH`；`display_flip_journal.noteVirtioPresentFlushBatch` 累计单次 present 内 flush 次数（多资源策略预留）。**光标队列** `CMD_MOVE_CURSOR`。`display.initAeroDwm` 后 `display_backend.syncFromVirtioScanout`（**`-Dforce_gop_present=true`** 时强制 `gop_linear`）。**阶段 4 Core**：`wddm_abstraction.CompositorBackend`（`cpu_full` / `cpu_with_virtio_present` / `future_gpu_assist`）与串口日志；`dwm.boxBlurRectBudgeted` 在 `cpu_full` 时**不**调用 `tryVirglBlurBoxDelegation`。**VirGL**：`CMD_SUBMIT_3D` **size=0** bring-up；**不接** 可执行 Gallium 流、**不**默认卸载 Aero 模糊。见 [VirtioVirglMVP.md](VirtioVirglMVP.md)、[PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](PHASE4_HARDWARE_SYSTEM_INTEGRATION.md)。**CPU 仍负责** memcpy 与盒式模糊 |
| x86_64 PS/2 与 VirtIO 双源 | **Partial** | [arch/x86_64/mod.zig](../../src/arch/x86_64/mod.zig) `handleMouseIrq`：VirtIO-Input 活跃且未 `-Dps2_mouse_with_virtio` 时 **跳过 IRQ12**；无 VirtIO 真机可编 `-Dps2_mouse_with_virtio=true` 或仅用 PS/2 |
| USB HID 鼠标 | **Partial（M1–M3 文档化）** | **M1**：`-Dusb_xhci=true` 枚举 + xHCI 桩，串口 **`USB: xhci_mvt`**；**M2**：`hid_boot_report.zig` Boot 报告 → `hid.zig` 注入；**M3**：`input_hub.pollAll` 顺序（USB → VirtIO → PS/2）见 `input_hub.zig` 与 PointerPolicy §4。主机 **hid_boot_report_host** |
| 注册表 `Mouse` / `DWM` → 壳层 | **Partial / 通知规则 Verified** | `dwm_config_registry_sync.hklm_dwm_policy_dword_names` 与 `registry.populateDefaults` / `dwm.syncPolicyFromRegistry` 同源；应用后按差异在 **已有窗口** 时补 `WM_DWM*`（无 HWND 启动豁免）；**`dwm_config_registry_sync_host`** |
| RegF / 原生 hive 全链；注册表 Native 子集 | **Partial** | **内存树 + ZOSH1**：[`hive.zig`](../../src/registry/hive.zig)；引导时依次尝试 `C:\System32\Config\ZirconUser.zosh` 与 **`D:\System32\Config\ZirconUser.zosh`**（NTFS 卷对称路径，阶段 4）；**RegF** 全解析仍为路线图；主机 **`registry_zosh1_host`**、**`ntfs_hive_minimum_host`**、**phase4_host_anchors** |

## 5. user32 / gdi32 与 Learn 抽样核对（返回值约定）

以下为实现中**已出现**的入口与公开文档应对齐的要点（clean-room 手写，禁止粘贴示例代码）。**实现标签**：Implemented = 行为与文档要点基本覆盖；Partial = 已知简化或 NT 差异已注释；Stub = 仅占位。

| API | Microsoft Learn（条目） | 文档关注点 | 实现 | 模块 |
|-----|-------------------------|------------|------|------|
| `CreateWindowEx` | [CreateWindowExA function](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-createwindowexa) | 成功 `HWND`，失败 `NULL` 与 `SetLastError` | **Implemented**（子集样式/类） | `user32.zig` |
| `DestroyWindow` | [DestroyWindow function](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-destroywindow) | 销毁顺序、`INVALID_HANDLE` | **Implemented**（+ `detachCompositorSurface`） | `user32.zig` |
| `GetDC` / `ReleaseDC` | [GetDC](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-getdc) / [ReleaseDC](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-releasedc) | 配对；`GetDC(NULL)` 屏幕 DC | **Partial**（`HDC==HWND`；`GetDC(0)` 成功返回 `0`） | `user32.zig` |
| `GetMessage` | [GetMessage function](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-getmessage) | 空队列阻塞；过滤范围 | **Partial**（`STATUS_PENDING` / 协作式；`min>max`（非 0,0）→ `ERROR_INVALID_PARAMETER`；见 syscall 注释） | `user32.zig`、`syscall.zig` |
| `PeekMessage` | [PeekMessageA function](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-peekmessagea) | `PM_REMOVE` / `PM_NOYIELD`；无消息返回 FALSE | **Partial**（`PM_*` 见 `msg_pm_semantics.zig`；`NtUserPeekMessage` 空队列 **`STATUS_NO_MORE_ENTRIES`** + 清零 `MSG*`；畸形 min/max 同上） | `user32.zig`、`msg_pm_semantics.zig` |
| `PostMessage` | [PostMessageA function](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-postmessagea) | 失败 `FALSE` 与 `SetLastError` | **Partial**（无效 HWND → `ERROR_INVALID_HANDLE`；队列满 → `ERROR_NOT_ENOUGH_MEMORY`；`NtUserPostMessage` 映 `STATUS_INVALID_PARAMETER` / `STATUS_NO_MEMORY`） | `user32.zig` |
| `DispatchMessage` | [DispatchMessage function](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-dispatchmessage) | 分派到 `WndProc` | **Partial**：`WindowClass.wndproc_id` + `registerKernelWndProc` 内核表；未命中 → **`DefWindowProcA`**（用户 VA `WndProc` 仍为路线图） | `user32.zig` |
| `SetWindowPos` | [SetWindowPos function](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-setwindowpos) | `HWND_*` 与 `SWP_*` | **Partial**（Learn `HWND_NOTOPMOST` 非 topmost 无 Z 序效果；扩展 `SWP_*` 常量；帧/重绘位忽略） | `user32.zig` |
| `CreateDesktop` / `OpenDesktop` / `SwitchDesktop` | [Desktops](https://learn.microsoft.com/windows/win32/winstation/desktops) | 桌面句柄与切换 | **Partial**（`subsystem.createUserDesktop` / `openDesktopByName` / `switchToDesktop`；`HDESK` 1-based） | `user32.zig`、`subsystem.zig` |
| `BeginPaint` / `EndPaint` | [BeginPaint](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-beginpaint) / [EndPaint](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-endpaint) | `PAINTSTRUCT` | **Partial**（`BeginPaint` / **`InvalidateRect`** 在有 compositor 表面时 `dwm_comp.markSurfaceDirty`） | `user32.zig` |
| `BitBlt` | [BitBlt function](https://learn.microsoft.com/windows/win32/api/wingdi/nf-wingdi-bitblt) | 成功非零；无效 DC | **Partial**（**仅 `SRCCOPY`**；其它 ROP → `FALSE` + `ERROR_INVALID_PARAMETER`；见 `gdi_rop_contract.zig`） | `gdi32.zig` |
| `PatBlt` | [PatBlt function](https://learn.microsoft.com/windows/win32/api/wingdi/nf-wingdi-patblt) | 同上 | **Partial**（`PATCOPY`/`BLACKNESS`/`WHITENESS`/`PATINVERT` 子集） | `gdi32.zig` |
| `StretchBlt` | [StretchBlt function](https://learn.microsoft.com/windows/win32/api/wingdi/nf-wingdi-stretchblt) | 同上 | **Partial**（**仅 `SRCCOPY`**；其余 ROP 同上） | `gdi32.zig` |
| `AlphaBlend` | [AlphaBlend function](https://learn.microsoft.com/windows/win32/api/wingdi/nf-wingdi-alphablend) | `BLENDFUNCTION`；成功非零 | **Partial**（**仅 `AC_SRC_OVER`** 存根；几何/像素混合计数；`gdi_rop_contract`） | `gdi32.zig` |
| `Rectangle` | [Rectangle function](https://learn.microsoft.com/windows/win32/api/wingdi/nf-wingdi-rectangle) | 成功非零 | **Partial** | `gdi32.zig` |
| `TextOut` | [TextOut function](https://learn.microsoft.com/windows/win32/api/wingdi/nf-wingdi-textouta) | 成功非零 | **Partial** | `gdi32.zig` |
| `CreateCompatibleDC` / `SelectObject` | [CreateCompatibleDC](https://learn.microsoft.com/windows/win32/api/wingdi/nf-wingdi-createcompatibledc) / [SelectObject](https://learn.microsoft.com/windows/win32/api/wingdi/nf-wingdi-selectobject) | 池/句柄错误 | **Partial** | `gdi32.zig` |
| `DeleteDC` | [DeleteDC function](https://learn.microsoft.com/windows/win32/api/wingdi/nf-wingdi-deletedc) | 不得释放 `GetDC` 窗口 DC | **Partial**（拒绝 HWND-as-HDC） | `gdi32.zig` |

完整列表随子系统扩展在 PR 中追加行。

### 5.1 user32 / gdi32：非目标边界与分阶段交付

下列能力**不**作为当前里程碑的「完成」标准（可与 [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) 对照）；实现以 **Aero / 内置 Shell 所需最小子集** 优先，每扩展一类 API 须更新上表与本节。

| 领域 | 非目标 / 长期项 | 分阶段说明 |
|------|-----------------|------------|
| GDI BitBlt | 完整 ROP3、拉伸、颜色格式矩阵、与打印机 DC 的完整交互 | **已实现子集**：`BitBlt`/`StretchBlt` 仅 `SRCCOPY`；`AlphaBlend` 仅 `AC_SRC_OVER` 存根；未支持 ROP 显式失败（主机 **gdi_rop_contract_host**）；完整 ROP 仍为 Planned |
| 字体 | ClearType/Uniscribe 级排版、完整 GDI 字体链接与回退 | 当前位图字体路径；FreeType 等为路线图项（见 API 矩阵 gdi32 行） |
| DC / 对象 | 完整 GDI 句柄表、跨进程 DC、元文件、路径 API | 以 `CreateCompatibleDC` / `SelectObject` 子集为主 |
| user32 消息 | 完整输入法、挂钩链、DDE、剪贴板全语义 | 消息泵与 DWM 广播等为 **Partial**；随契约矩阵增行；**阶段 D 分解清单**见 [PHASE_D_WIN32_MSG_PUMP_DWM.md](PHASE_D_WIN32_MSG_PUMP_DWM.md) |

**user32**：优先保证 `GetMessage` / `PeekMessage`、`CreateWindowEx` 等与壳路径一致的入口；模态环与 NC 命中等为部分语义，须在 PR 中注明已知差距。

### 5.2 Shell / 脚本宿主（与 Microsoft PowerShell 的边界）

| 能力（文档概念） | 状态 | 说明 |
|------------------|------|------|
| **PowerShell** / cmdlet 脚本宿主 | **不适用（内核）** | 内核侧 **不实现** PowerShell 引擎；历史上 in-kernel ZirconShell 已移除。 |
| 用户态 **.NET** 脚本宿主（未来） | **Planned（仓库外）** | 与 PowerShell 公开 **行为与 cmdlet 模型** 对齐的宿主应在 **独立用户态程序 / 仓库** 实现；本仓库仅提供 Native / LPC / 对象等内核能力。 |
| 命令提示符（`cmd.exe` 语义子集） | Partial | `src/subsystems/win32/cmd.zig` 等；与上项正交。 |

### 5.3 主机回归（win32k 语义锚点）

| 主题 | `zig build test` 步 | 说明 |
|------|---------------------|------|
| PM_* / LPC 偏移 / GDI ROP 子集 / Flip3D 数值 cap | **win32k_api_semantics_host** | [tests/nt61/win32k_api_semantics_host.zig](../../tests/nt61/win32k_api_semantics_host.zig) |
| GDI ROP 清单 | **gdi_rop_contract_host** | [gdi_rop_contract.zig](../../src/subsystems/win32/gdi_rop_contract.zig) |

## 6. 配置语义：`nt_product_arch` 与宿主 CPU

- **`system.nt_product_arch`**（嵌入 `system.conf`）：NT 6.1 **兼容层所宣称的产品处理器族**（如始终报告 `x86_64` 以匹配 WOW64/子集行为），**不等于** QEMU/固件实际 CPU。
- **宿主架构**：运行期以 `builtin.cpu.arch` 为准；`config.hostCpuArchName()` 与 `arch.impl.name` 用于串口/诊断。

## 7. 相关仓库文档

- [NT61_PR_GATES.md](NT61_PR_GATES.md) — **K0 PR 门禁勾选清单**（契约矩阵、MVT、syscall 注释、合规扫描）  
- [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) — **NT 6.1 内核模式分阶段待办（K0–K8）**与 clean-room 门禁；PR 与契约矩阵 §8 同步推进  
- [NT61_FULL_API_BACKLOG.md](NT61_FULL_API_BACKLOG.md) — **完整 NT 6.1 API 能力 backlog**（与当前基础迭代分离的长期清单）
- [NT61_WINMSG_API_TRACKER.md](NT61_WINMSG_API_TRACKER.md) — **窗口消息 / user32 契约与代码路径追溯表**  
- [MVT_NT61.md](MVT_NT61.md) — 最小可验证测试索引（主机测试 + CI）  
- [DWM_NOTIFY_MODEL_NT61.md](DWM_NOTIFY_MODEL_NT61.md) — `WM_DWM*` 与监听线程等价叙事  
- [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) — 不阻塞内核主里程碑的延后能力（WDDM / 完整 Win32 / WOW64 / AML 等）  
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
| 每 CPU 就绪队列与工作窃取 | `src/ke/scheduler.zig`（32 级分桶 FIFO、`non_empty`、窃取、`pickBalancedHomeCpu`）；`percpu_sched.zig`（空闲线程等）；亲和 `setThreadAffinityMask` | `zig build test` → **scheduler_policy_host**（公式）；QEMU 烟测 |
| TLB 一致性（SMP 前占位） | `src/hal/x86_64/tlb_broadcast.zig` | Debug 下多 CPU 时串口诊断；未来 IPI 用例 |
| LPC 端口种类 | `src/lpc/port.zig` `PortKind` | `zig build test` → **lpc_portkind_host**；[LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) |
| IRP 完成例程与栈下传 | `src/io/io.zig` `IoCompleteRequest`、`dispatchIrpThroughStack` | 主机：`tests/io_irp_host.zig`（完成例程 + 栈链镜像断言） |
| 对象路径规范化 / 符号链接（单层） | `src/ob/object.zig` `normalizeNtObjectPath`、`insertSymbolicLink`、`normalizeNtObjectPathResolveSymlinks` | `zig build test` → `object` |
| 合规短语扫描 | `scripts/verify-compliance.sh` | CI：`Compliance phrase scan (src/boot)` |
| `NtQuerySystemInformation` 子集 | `src/libs/ntdll.zig` | syscall + ntdll 一致性审查 |
| `NtReadFile` / `NtWriteFile` syscall → VFS | `syscall_nt_extras.zig`、`ntdll.zig`、`vfs.zig` | 指针探测 + `zig build test`；QEMU 烟测扩展 |
| `NtDuplicateObject`（同进程） | `ntdll.zig`、`syscall_nt_extras.zig`；SSDT `0x44` | **ssdt_stub_parity**（`NtDuplicateObject` 号）；句柄表 **object** 测试 |
| `NtRequestWaitReplyPort`（简化 ABI） | `syscall_nt_extras.zig`、`lpc/port.zig` | **lpc_portkind_host** + 代码审查 |
| VirtIO-Blk 枚举占位 | `virtio_blk_pci.zig`、`acpi_pci_early.zig`；`pci_driver_bind` | **pci_driver_bind_host**（`virtio_blk` 绑定） |
| 完整 API 长期 backlog | [NT61_FULL_API_BACKLOG.md](NT61_FULL_API_BACKLOG.md) | 文档跟踪；与 K0–K8 交付分离 |

**合规**：实现仅依据 MS Learn / WDK 公开描述与硬件规范；提交前运行 `bash scripts/verify-compliance.sh`。

## 9. KUSER_SHARED_DATA / TEB / Win32k 分流（加载微软 ntdll — 长期）

| 表面 | 公开依据 | 状态 |
|------|----------|------|
| `KUSER_SHARED_DATA` 用户映射页（时标、系统调用间隔等） | WDK `KUSER_SHARED_DATA` DDI | **Partial** — x64 进程创建时映射 `0x7FFE0000` 只读页并写版本桩；见 [`mm/kuser_shared.zig`](../../src/mm/kuser_shared.zig)、[`sdk/kuser_shared_nt61.zig`](../../src/sdk/kuser_shared_nt61.zig)；**ntdll 合成基址** 迁至 `0x7FF6_0000_0000` 避免冲突 |
| PEB / TEB 中线程与进程信息；`LastErrorValue` x64 偏移 | Learn — 进程线程；调试器实践 | **Partial** — [`sdk/teb_nt61_x64.zig`](../../src/sdk/teb_nt61_x64.zig) 断言 `@offsetOf(LastErrorValue)==0x68`；主机测试 **nt61_abi_layout_host** |
| Win32k 与 ntos SSDT 分流；全局 ATOM 占位 | x64 上多表/MSR；Learn 原子表概念 | **Partial** — 本内核将部分用户消息 syscall 折叠进主 SSDT，见 [SyscallABI.md](SyscallABI.md)；[`win32k/atoms.zig`](../../src/subsystems/win32k/atoms.zig) |
| 用户态 `Nt*` → `syscall` 薄层 | AMD64 调用约定 | **Partial** — [`src/sdk/ntdll_syscall_win64.zig`](../../src/sdk/ntdll_syscall_win64.zig)；内核内联桩仍为 `src/libs/ntdll.zig` |

### 9.1 WOW64：覆盖与已知缺口

**阶段 G 专文**（与 Roadmap Phase 11 区分）：[PHASE_G_WOW64.md](PHASE_G_WOW64.md)。

| 项目 | 状态说明 | 代码 / 文档 |
|------|----------|-------------|
| x86（32 位）原生服务号 **公开子集**（与 x64 表不同号） | **Partial** — 对照 j00ru `x86/json/nt-per-system.json` Win7 SP1 | [`ssdt_x86_win7_sp1.zig`](../../src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig)；主机测试 **wow64_ssdt_x86**、**ssdt_x64_x86_namespace**；[PHASE_G_WOW64.md](PHASE_G_WOW64.md) |
| 64 位内核 SSDT 子集 | **Partial** | [`ssdt_nt61.zig`](../../src/arch/x86_64/ssdt_nt61.zig)；与 x86 同名 API 对照见 [`x64_semantic_alias.zig`](../../src/subsystems/win32/wow64/x64_semantic_alias.zig) |
| `translateSyscall32to64` / `WithArgs` | **Partial** — stub 列表 + `last_x64_ssdt_alias`；`marshal.zig` 另覆盖 `NtAllocateVirtualMemory` / `NtFreeVirtualMemory` / `NtDuplicateObject`（x86 **0x39**）/ `NtReadFile` / `NtWriteFile`（用户 `IO_STATUS_BLOCK` 回写）；`userVaFromWow64Ptr32` 与 `thunk` 导出对齐；x86 **win32k**（`≥0x1000`）仍 `STATUS_NOT_IMPLEMENTED`；`NtTerminateThread` x64 索引 ZOA **0x55** 注释见 `ssdt_nt61` | [`wow64/thunk.zig`](../../src/subsystems/win32/wow64/thunk.zig)、[`marshal.zig`](../../src/subsystems/win32/wow64/marshal.zig)、[`x64_semantic_alias.zig`](../../src/subsystems/win32/wow64/x64_semantic_alias.zig)、`syscall.zig`、[PHASE_G_WOW64.md](PHASE_G_WOW64.md) |
| 32 位 PEB / TEB 布局 | **Partial** — `PEB32`/`TEB32` 为 `extern` 子集 + comptime 偏移测试；演示 VA 与 `ProcessWow64Information`；用户页真实映射仍依阶段 F | [`wow64/types.zig`](../../src/subsystems/win32/wow64/types.zig)、[`ps/process.zig`](../../src/ps/process.zig)、[`ntdll.zig`](../../src/libs/ntdll.zig) |
| 文件 / 注册表重定向 | **Partial** — UTF-16LE `System32`→`SysWOW64`（`ntdll` `NtCreateFile`/`NtOpenFile`）；`\Registry\Machine\SOFTWARE\`→`Wow6432Node`（`syscall` `NtOpenKey`/`NtCreateKey`）；**反重定向**（system32 下 native 工具）等为后续项 | [`wow64/redirect.zig`](../../src/subsystems/win32/wow64/redirect.zig)、[`registry/registry.zig`](../../src/registry/registry.zig) |
| 地址空间隔离 | **Partial** — WOW64 进程模型与栈/堆基址为简化演示 | `wow64.zig` |
| `dwmapi` PE32 结构 / HWND 扩展 | **Partial** — `DWM_BLURBEHIND32` 等 ILP32 布局与 `hwnd32ToNative`；完整 thunk 表仍为路线图 | [`dwmapi_wow64.zig`](../../src/subsystems/win32/dwmapi_wow64.zig)；**dwmapi_wow64_host** |

### 9.2 csrss 风格子系统与 LPC 里程碑

| 阶段 | 内容 | 状态 |
|------|------|------|
| M1 | LPC 端口创建/连接、`PortKind` ABI 稳定；与 [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) 一致 | **Partial** — `ipc.zig` 队列自旋锁、`requestWaitReplyPort` 校验 `owner_pid`；`port.handshake_version`；**lpc_portkind_host** |
| M2 | `subsystem.zig` 中进程注册、会话/窗口站/桌面 **数据结构** 与 CSR API 号枚举；**`register_dwm_listener` v1** 载荷（[LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md)） | **Partial** — [`subsystem.zig`](../../src/subsystems/win32/subsystem.zig) `CsrApiNumber`、Desktop/WindowStation；`csr_lpc_policy.readRegisterDwmListenerRawTid` |
| M3 | 完整窗口站/桌面 **安全边界**、会话 0 隔离、与 LPC 大消息/节区视图握手的生产语义 | **Planned** — 握手占位见 LPC 文档 §与子系统 |
| M4 | 与真实 csrss 相当的进程生命周期、控制台/ GUI 分流、全消息泵协议 | **长期** — 见文首「现实落差」与延后表面文档 |
| M4a | **阶段 4**：`CsrApiNumber` `0x10028`–`0x1002A`（`open_desktop` / `switch_desktop_lpc` / `close_desktop_lpc`）+ `LPC_NT61_HANDSHAKE.md` vNext 载荷；`port.requestWaitReplyPort` 对 `open_desktop` 复制 `HDESK` 应答 | **Partial** — `subsystem.handleApiCall` + 主机 **phase4_host_anchors**；活动桌面校验与 `close` 禁 Default |

## 10. Clean-room 内核里程碑跟踪（与实现 PR 同步）

| 门禁 / 能力 | 说明 | 验证 |
|-------------|------|------|
| 合规短语扫描 | 禁止违规来源表述；`src/`、`boot/` 源扫描 | `bash scripts/verify-compliance.sh`；CI **Compliance phrase scan** |
| ECAM 偏移公式 | PCIe MCFG MMIO 布局与 `acpi_pci_early` 一致 | `zig build test` → **ecam_layout** |
| HPET GCAP_ID 解码 | IA-PC HPET 规范位域（无 MMIO 依赖） | `zig build test` → **hpet_id** |
| HPET MMIO 探测 + 主计数器 | `hal/x86_64/hpet.zig`；tick 仍为 PIT | QEMU/实机串口 `HPET:` 行；`isCalibratedForTickMigration()` |
| 互斥优先级继承深度 | 多锁并行时 `mutex_inherit_depth` / `endMutexInheritance` | `zig build test` → **mutex_inherit_depth_host**；[SCHEDULER_API.md](SCHEDULER_API.md) |
| LPC `PortKind` 判别值 | csrss 握手 ABI 稳定 | `zig build test` → **lpc_portkind_host**；[LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) |
| IPv4 首部解析子集 | RFC 791 固定头（网络栈原型） | `zig build test` → **minimal_net** |
| MDL 最小子集 | WDK MDL 概念：VA/长度、内联 PFN 槽、恒等映射填 PFN 占位（无真实锁页 / 散列 DMA） | `zig build test` → **mdl_host**；[NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) K1.7 |
| IRP MJ PnP/Power 占位 | WDK 概念对齐的 major 序号 | `src/io/io.zig` `comptime` 断言；主机 **io_irp_host**（完成例程契约 + PnP/Power 序号） |
| VFS 访问掩码常量 | `FileAccessMode` 与 NT 风格 GENERIC 位一致 | `zig build test` → **fs_vfs_constants_host** |
| PCI 类/厂商 → 驱动绑定表（占位） | `src/drivers/bus/pci_driver_bind.zig`；供 USB/显示等枚举后选型 | `zig build test` → **pci_driver_bind_host** |
| SMP TLB 占位诊断 | 多逻辑 CPU：`unmapRange` 递增 `noteUserMappingInvalidatedSmp`；全局 flush 仍为 BSP 本地 | `tlb_broadcast.zig`；Debug 构建串口提示 |
