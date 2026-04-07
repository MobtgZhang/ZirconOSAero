# ZirconOSAero 文档（中文）

ZirconOSAero 是基于 Zig 的 **NT 6.1 目标混合微内核操作系统**。内核除机制（调度、虚拟内存、IPC、中断、系统调用）外，仍含大量 **Executive**（对象、I/O、安全、加载器等 — 见 [Architecture.md](Architecture.md)）；**独立用户态**当前主要为 Process Server、SMSS 与 Win32 侧库。Win32 兼容为**文档化子集**，非零售 Windows 等价。

**英文总索引**：[../README.md](../README.md) · **全部分类列表**：[../DOCS_INDEX.md](../DOCS_INDEX.md) · **文档职责划分**：[../DOCS_MAINTAINERS.md](../DOCS_MAINTAINERS.md) · **可复现构建**：[../REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) · **English pages**：[`../en/`](../en/)

## Phase / 路线图命名区分（权威说明）

下文 **阶段 D–G**、**阶段 4** 等文档中的「Phase」与 [Roadmap.md](Roadmap.md) 中 **Phase 0–11** 里程碑 **不是同一套编号**。对应关系与范围以各阶段文档文首一句为准；避免在其它文中重复长段解释。

**另一套编号：内核初始化 Phase 0–12** — [Boot.md](Boot.md)、[Kernel.md](Kernel.md) 与 `src/main.zig` 中的 **顺序拉起步骤** 使用 **0–12**；与路线图 **0–11** **不是同一计数**。勿把「Phase 11 里程碑」与「init Phase 11」混为一谈。

| 文档中的名称 | 与 Roadmap 的关系（摘要） |
|--------------|---------------------------|
| [PHASE_D_WIN32_MSG_PUMP_DWM.md](PHASE_D_WIN32_MSG_PUMP_DWM.md) | 消息泵 / DWM / LPC；≠ PLAN_REMAINING 内「Phase D 合成器」全文 |
| [PHASE_E_NATIVE_API.md](PHASE_E_NATIVE_API.md) | Native / SSDT / ntdll 深度；≠ PLAN_REMAINING「Phase E — Shell」 |
| [PHASE_F_PROCESS_CREATE.md](PHASE_F_PROCESS_CREATE.md) | `NtCreateUserProcess` 等；≠ PLAN_REMAINING「Phase F — 集成」 |
| [PHASE_G_WOW64.md](PHASE_G_WOW64.md) | WOW64 可测子集；≠ Roadmap「Phase 11 — WOW64 + 音频」全文 |
| [PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](PHASE4_HARDWARE_SYSTEM_INTEGRATION.md) | 硬件呈现 + csrss + WOW64 + NTFS 等官方范围 |

## 核心三件套（契约 / 验证 / 内核待办）

| 文档 | 用途 |
|------|------|
| [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) | 子系统承诺与状态矩阵 |
| [MVT_NT61.md](MVT_NT61.md) | 可复现验证与 `zig build test` 映射 |
| [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) | 内核 K0–K8 待办 |
| [NT61_PR_GATES.md](NT61_PR_GATES.md) | PR 合并前勾选（含文档链接检查） |
| [API_COMPAT_MATRIX.md](API_COMPAT_MATRIX.md) | Win32/Native API 骨架表 |
| [NT61_FULL_API_BACKLOG.md](NT61_FULL_API_BACKLOG.md) | 长期全量 API 面（非当前交付） |
| [PROCESS_NT61.md](PROCESS_NT61.md) | 流程与门禁 |
| [IMPLEMENTATION_STATUS_NT61.md](IMPLEMENTATION_STATUS_NT61.md) | 实现状态摘要 |
| [BINARY_COMPAT_GAP_AUDIT.md](BINARY_COMPAT_GAP_AUDIT.md) | 二进制兼容缺口优先级 |
| [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md) | 未完成滚动清单 |

## 架构与构建（与 `en/` 成对）

| 文档 | 说明 |
|------|------|
| [Architecture.md](Architecture.md) | 总体架构 |
| [Kernel.md](Kernel.md) | 内核实现 |
| [Boot.md](Boot.md) | 启动与 Phase 0–12 |
| [Servers.md](Servers.md) | 系统服务 |
| [Subsystems.md](Subsystems.md) | 子系统 |
| [BuildSystem.md](BuildSystem.md) | **主入口 `zig build`**；`Makefile` / `build.conf` / `run.sh` 为便捷封装 |
| [Roadmap.md](Roadmap.md) | Phase 0–11 路线图 |
| [BootPhasesAndNt61Loader.md](BootPhasesAndNt61Loader.md) | 引导与加载器细节 |
| [TIER2_ARCHITECTURES.md](TIER2_ARCHITECTURES.md) | 次架构 |
| [COPYRIGHT_AND_SOURCES.md](COPYRIGHT_AND_SOURCES.md) | 版权与知识来源 |

## 桌面、DWM、消息、图形

| 文档 | 说明 |
|------|------|
| [DesktopManagerSpec.md](DesktopManagerSpec.md) | 桌面 / 窗口站 / DWM |
| [DesktopQA.md](DesktopQA.md) | 桌面验证清单 |
| [AeroDesktopRuntime.md](AeroDesktopRuntime.md) | 数据流、QEMU、输入 |
| [AeroRendering.md](AeroRendering.md) | Aero 渲染 |
| [DpiDesktop.md](DpiDesktop.md) | 高 DPI；**外部 desktop-src 索引说明见该文** |
| [DWM_NOTIFY_MODEL_NT61.md](DWM_NOTIFY_MODEL_NT61.md) | DWM 通知模型 |
| [SOFTWARE_COMPOSITOR_WDDM.md](SOFTWARE_COMPOSITOR_WDDM.md) | 软件合成与 WDDM |
| [NT61_GRAPHICS_SCAFFOLD.md](NT61_GRAPHICS_SCAFFOLD.md) | 图形脚手架 |
| [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) | 推迟的表面 / 完整 win32k 等 |
| [NT61_WINMSG_API_TRACKER.md](NT61_WINMSG_API_TRACKER.md) | 消息 API 跟踪 |
| [Win32kArchitectureNotes.md](Win32kArchitectureNotes.md) | win32k 路线笔记 |
| [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) | LPC 握手 |
| [LPC_USER_SERVERS_CONTRACT.md](LPC_USER_SERVERS_CONTRACT.md) | 用户态服务 LPC 契约 |
| [VirtioVirglMVP.md](VirtioVirglMVP.md) | VirtIO/VirGL |

## 内存、调度、syscall、I/O

| 文档 | 说明 |
|------|------|
| [MM_ALLOC_PATHS.md](MM_ALLOC_PATHS.md) | 分配路径 |
| [MM_HEAP_POOL_SLAB.md](MM_HEAP_POOL_SLAB.md) | 堆 / 池 / slab |
| [MM_Section_Roadmap.md](MM_Section_Roadmap.md) | 节区 |
| [VM_ISOLATION.md](VM_ISOLATION.md) | 地址空间隔离 |
| [NT61_VirtualMemory_ABI_Notes.md](NT61_VirtualMemory_ABI_Notes.md) | VM ABI 笔记 |
| [PHYS_ALLOC_AUDIT.md](PHYS_ALLOC_AUDIT.md) | 物理分配审计 |
| [PFN_REFCOUNT_ROADMAP.md](PFN_REFCOUNT_ROADMAP.md) | PFN 引用 |
| [PointerPolicy_NT61.md](PointerPolicy_NT61.md) | 指针策略 |
| [SCHEDULER_API.md](SCHEDULER_API.md) | 调度器 API |
| [TimerPrecisionRoadmap.md](TimerPrecisionRoadmap.md) | 定时精度 |
| [SyscallABI.md](SyscallABI.md) | syscall ABI |
| [SSDT_Roadmap.md](SSDT_Roadmap.md) | SSDT |
| [STORAGE_IO_ROADMAP.md](STORAGE_IO_ROADMAP.md) | 存储与 IRP |
| [HAL_USB_NET_ROADMAP.md](HAL_USB_NET_ROADMAP.md) | HAL / USB / 网络 |
| [ARCH_SMP_NET_MATRIX.md](ARCH_SMP_NET_MATRIX.md) | 多架构 / SMP / 网络 |

## PE、Shell、内置应用、资源

| 文档 | 说明 |
|------|------|
| [CORE_DLL_PE_EXPORT_STRATEGY.md](CORE_DLL_PE_EXPORT_STRATEGY.md) | 核心 DLL 导出 |
| [DWMAPI_PE_EXPORT_STRATEGY.md](DWMAPI_PE_EXPORT_STRATEGY.md) | dwmapi 导出 |
| [NT61_ShellIcons.md](NT61_ShellIcons.md) | 壳层图标 |
| [BuiltinApps_NT61_Roadmap.md](BuiltinApps_NT61_Roadmap.md) | 内置应用 |
| [Assets.md](Assets.md) | 资源合规 |

## 里程碑与驱动

| 文档 | 说明 |
|------|------|
| [ExecutivePhase3_Milestones.md](ExecutivePhase3_Milestones.md) | Executive Phase3 |
| [DriverMilestones_NT61.md](DriverMilestones_NT61.md) | 驱动里程碑 |

**更细的条目与 en/cn 对照**：见 [../DOCS_INDEX.md](../DOCS_INDEX.md)。**仓库目录树与根 README 特性矩阵**：见仓库根目录 [README.md](../../README.md)。

## 核心技术栈

- **语言**: Zig（内核构建无 libc 依赖）；**主构建**：`zig build`（`minimum_zig_version` 见 `build.zig.zon`；CI 锁定见 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md)）
- **架构**: x86_64（主要）、aarch64、loongarch64、riscv64；mips64el 试验
- **引导**: 仅 ZBM；Multiboot2 handoff
- **运行环境**: QEMU
