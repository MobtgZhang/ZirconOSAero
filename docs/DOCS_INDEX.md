# ZirconOSAero 文档索引（分类表）

> **机器可读索引**：按职责分类，标明主文档/附录与语言。
> **状态标签定义**见下方 `STATUS_LEGEND`。
> **维护契约与验证命令**以 [cn/NT61_CONTRACT_MATRIX.md](cn/NT61_CONTRACT_MATRIX.md)、[cn/MVT_NT61.md](cn/MVT_NT61.md)、[cn/NT61_KERNEL_TODO.md](cn/NT61_KERNEL_TODO.md) 及本文档 §维护约定为准。

---

## STATUS_LEGEND（统一状态标签）

| 标签 | 含义 | 说明 |
|------|------|------|
| **Done** | 完全实现 | 通过自动化测试验证，生产可用 |
| **Partial** | 实现子集 | API/行为与 NT 6.1 一致的部分已实现；其余部分尚不完整 |
| **Stub** | 函数存在但仅返回成功/NULL | 不改变行为，仅满足调用约定 |
| **Planned** | 规划中 | 有明确设计但未开始实现 |
| **Not-Started** | 尚未开始 | 记录为未来工作项，当前无代码 |
| **Verified** | 契约标记 | 在契约矩阵中标记为已通过验证的能力 |

> **注意**：旧文档中的「部分」「已完成」「占位」「done」等非标准词汇已统一为本表标签。
> 跨文档引用时，请使用本表标签而非自定义描述。

---

## 维护约定

以下说明 **哪份文档维护什么**；其它文档应单句引用此处或三件套，避免复制长表。

| 文档 | 维护内容 |
|------|----------|
| [cn/NT61_CONTRACT_MATRIX.md](cn/NT61_CONTRACT_MATRIX.md) | 子系统/能力 **承诺边界**、状态列（Done / Partial / Stub / Planned / Verified），与实现对齐的叙事 |
| [cn/MVT_NT61.md](cn/MVT_NT61.md) | **可复现验证**：命令、`zig build test` 步骤名、源码/测试路径映射 |
| [cn/NT61_KERNEL_TODO.md](cn/NT61_KERNEL_TODO.md) | 内核模式 **K0–K8** 落地任务与主要源码路径 |
| [cn/NT61_FULL_API_BACKLOG.md](cn/NT61_FULL_API_BACKLOG.md) | **长期**全量 NT API 面；不表示已实现；分节 CI 锚点见文内 |
| [cn/API_COMPAT_MATRIX.md](cn/API_COMPAT_MATRIX.md) | **Win32/Native API** 骨架一行表；随 PR 更新；细节以契约矩阵为准 |
| [cn/NT61_PR_GATES.md](cn/NT61_PR_GATES.md) | 合并前人类勾选；含文档链接检查命令 |
| [REPRODUCE_BUILD.md](REPRODUCE_BUILD.md) | Zig/QEMU 版本、Release、与 CI 对齐的构建命令 |
| [`scripts/check-docs-links.sh`](../scripts/check-docs-links.sh) | `docs/` 相对链接完整性（`bash scripts/check-docs-links.sh`） |

**交叉引用规则**：非 Hub 页底部「相关链接」宜 ≤5 条，优先指向契约矩阵、MVT、KERNEL_TODO 之一。

**文档更新原则**：PR 涉及语义变更时，必须同步更新对应文档；若扩大 Win32/WOW64/ntdll/csrss/user32/gdi32 的完成度表述，须同时更新 [cn/NT61_CONTRACT_MATRIX.md](cn/NT61_CONTRACT_MATRIX.md) 与（如适用）[cn/API_COMPAT_MATRIX.md](cn/API_COMPAT_MATRIX.md)，并在 [cn/MVT_NT61.md](cn/MVT_NT61.md) 或 `tests/` 增加可复现验证。

**最后更新**：2026-04-10

---

## 入口（Hub）

| 文件 | 语言 | 角色 |
|------|------|------|
| [README.md](README.md) | EN | 英文总索引；链接 `en/` 与中文技术文档分组 |
| [en/NT61_REFERENCE.md](en/NT61_REFERENCE.md) | EN | NT61 中文深度文档的英文入口 |
| [cn/README.md](cn/README.md) | CN | 中文总索引；NT 6.1 技术文档主入口 |
| [REPRODUCE_BUILD.md](REPRODUCE_BUILD.md) | CN | 可复现构建、Zig/QEMU 版本、Release 检查清单 |

---

## 架构与构建（en/cn 成对）

| 文件 | 语言 | 备注 |
|------|------|------|
| [en/Architecture.md](en/Architecture.md) / [cn/Architecture.md](cn/Architecture.md) | EN / CN | 成对 |
| [en/Kernel.md](en/Kernel.md) / [cn/Kernel.md](cn/Kernel.md) | EN / CN | 成对 |
| [en/Boot.md](en/Boot.md) / [cn/Boot.md](cn/Boot.md) | EN / CN | 成对 |
| [en/Servers.md](en/Servers.md) / [cn/Servers.md](cn/Servers.md) | EN / CN | 成对 |
| [en/Subsystems.md](en/Subsystems.md) / [cn/Subsystems.md](cn/Subsystems.md) | EN / CN | 成对 |
| [en/BuildSystem.md](en/BuildSystem.md) / [cn/BuildSystem.md](cn/BuildSystem.md) | EN / CN | 成对；`Makefile` 为便捷封装，主入口 `zig build` |
| [cn/BootPhasesAndNt61Loader.md](cn/BootPhasesAndNt61Loader.md) | CN | 引导与加载器细节 |
| [cn/TIER2_ARCHITECTURES.md](cn/TIER2_ARCHITECTURES.md) | CN | 次架构说明 |

---

## NT 6.1 契约、验证与内核待办（核心三件套 + 闸门）

| 文件 | 语言 | 角色 |
|------|------|------|
| [cn/NT61_CONTRACT_MATRIX.md](cn/NT61_CONTRACT_MATRIX.md) / [en/NT61_CONTRACT_MATRIX.md](en/NT61_CONTRACT_MATRIX.md) | CN / EN | **主**：子系统承诺边界、状态列 |
| [cn/MVT_NT61.md](cn/MVT_NT61.md) / [en/MVT_NT61.md](en/MVT_NT61.md) | CN / EN | **主**：可复现验证步骤与 `zig build test` 映射 |
| [cn/NT61_KERNEL_TODO.md](cn/NT61_KERNEL_TODO.md) | CN | **主**：内核 K0–K8 落地项 |
| [cn/NT61_PR_GATES.md](cn/NT61_PR_GATES.md) / [en/NT61_PR_GATES.md](en/NT61_PR_GATES.md) | CN / EN | PR 人类勾选与文档链接检查 |
| [cn/PROCESS_NT61.md](cn/PROCESS_NT61.md) / [en/PROCESS_NT61.md](en/PROCESS_NT61.md) | CN / EN | 流程与门禁（与矩阵同源） |
| [cn/IMPLEMENTATION_STATUS_NT61.md](cn/IMPLEMENTATION_STATUS_NT61.md) / [en/IMPLEMENTATION_STATUS_NT61.md](en/IMPLEMENTATION_STATUS_NT61.md) | CN / EN | 实现状态摘要 |
| [cn/API_COMPAT_MATRIX.md](cn/API_COMPAT_MATRIX.md) | CN | Win32/Native API 骨架表（与矩阵 §5 互补；PR 随能力更新） |
| [cn/NT61_FULL_API_BACKLOG.md](cn/NT61_FULL_API_BACKLOG.md) / [en/NT61_FULL_API_BACKLOG.md](en/NT61_FULL_API_BACKLOG.md) | CN / EN | 长期全量 API 面（非当前交付承诺） |
| [cn/BINARY_COMPAT_GAP_AUDIT.md](cn/BINARY_COMPAT_GAP_AUDIT.md) | CN | 二进制兼容缺口优先级 |
| [cn/NT61_PLAN_REMAINING.md](cn/NT61_PLAN_REMAINING.md) / [en/NT61_PLAN_REMAINING.md](en/NT61_PLAN_REMAINING.md) | CN / EN | 未完成滚动清单 |
| [cn/NT61_DEFERRED_SURFACES.md](cn/NT61_DEFERRED_SURFACES.md) / [en/NT61_DEFERRED_SURFACES.md](en/NT61_DEFERRED_SURFACES.md) | CN / EN | 延迟事项（不在主线交付范围） |
| [cn/NT61_VirtualMemory_ABI_Notes.md](cn/NT61_VirtualMemory_ABI_Notes.md) / [en/NT61_VirtualMemory_ABI_Notes.md](en/NT61_VirtualMemory_ABI_Notes.md) | CN / EN | 虚拟内存 ABI 注记 |

---

## 路线图与阶段文档（Phase 编号见 cn/README「命名区分」）

| 文件 | 语言 |
|------|------|
| [en/Roadmap.md](en/Roadmap.md) / [cn/Roadmap.md](cn/Roadmap.md) | EN / CN |
| [cn/PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](cn/PHASE4_HARDWARE_SYSTEM_INTEGRATION.md) / [en/PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](en/PHASE4_HARDWARE_SYSTEM_INTEGRATION.md) | CN / EN |
| [cn/PHASE_D_WIN32_MSG_PUMP_DWM.md](cn/PHASE_D_WIN32_MSG_PUMP_DWM.md) / [en/PHASE_D_WIN32_MSG_PUMP_DWM.md](en/PHASE_D_WIN32_MSG_PUMP_DWM.md) | CN / EN |
| [cn/PHASE_E_NATIVE_API.md](cn/PHASE_E_NATIVE_API.md) / [en/PHASE_E_NATIVE_API.md](en/PHASE_E_NATIVE_API.md) | CN / EN |
| [cn/PHASE_F_PROCESS_CREATE.md](cn/PHASE_F_PROCESS_CREATE.md) / [en/PHASE_F_PROCESS_CREATE.md](en/PHASE_F_PROCESS_CREATE.md) | CN / EN |
| [cn/PHASE_G_WOW64.md](cn/PHASE_G_WOW64.md) / [en/PHASE_G_WOW64.md](en/PHASE_G_WOW64.md) | CN / EN |
| [cn/ExecutivePhase3_Milestones.md](cn/ExecutivePhase3_Milestones.md) | CN |
| [cn/DriverMilestones_NT61.md](cn/DriverMilestones_NT61.md) | CN |

---

## 内存、VM、节区与物理页

| 文件 | 语言 |
|------|------|
| [cn/MM_ALLOC_PATHS.md](cn/MM_ALLOC_PATHS.md) | CN |
| [cn/MM_HEAP_POOL_SLAB.md](cn/MM_HEAP_POOL_SLAB.md) | CN |
| [cn/MM_Section_Roadmap.md](cn/MM_Section_Roadmap.md) | CN |
| [cn/VM_ISOLATION.md](cn/VM_ISOLATION.md) | CN |
| [cn/NT61_VirtualMemory_ABI_Notes.md](cn/NT61_VirtualMemory_ABI_Notes.md) / [en/NT61_VirtualMemory_ABI_Notes.md](en/NT61_VirtualMemory_ABI_Notes.md) | CN / EN |
| [cn/MemoryManagement_NT61_LoongArch64_NewWorld.md](cn/MemoryManagement_NT61_LoongArch64_NewWorld.md) / [en/MemoryManagement_NT61_LoongArch64_NewWorld.md](en/MemoryManagement_NT61_LoongArch64_NewWorld.md) | CN / EN |
| [cn/PHYS_ALLOC_AUDIT.md](cn/PHYS_ALLOC_AUDIT.md) | CN |
| [cn/PFN_REFCOUNT_ROADMAP.md](cn/PFN_REFCOUNT_ROADMAP.md) | CN |
| [cn/PointerPolicy_NT61.md](cn/PointerPolicy_NT61.md) | CN |

---

## 调度、定时、syscall / SSDT

| 文件 | 语言 |
|------|------|
| [cn/SCHEDULER_API.md](cn/SCHEDULER_API.md) | CN |
| [cn/TimerPrecisionRoadmap.md](cn/TimerPrecisionRoadmap.md) | CN |
| [cn/SyscallABI.md](cn/SyscallABI.md) | CN |
| [cn/SSDT_Roadmap.md](cn/SSDT_Roadmap.md) | CN |

---

## I/O、存储、HAL、网络

| 文件 | 语言 |
|------|------|
| [cn/STORAGE_IO_ROADMAP.md](cn/STORAGE_IO_ROADMAP.md) | CN |
| [cn/HAL_USB_NET_ROADMAP.md](cn/HAL_USB_NET_ROADMAP.md) | CN |
| [cn/ARCH_SMP_NET_MATRIX.md](cn/ARCH_SMP_NET_MATRIX.md) | CN |

---

## 桌面、DWM、Win32 消息、GDI、图形脚手架

| 文件 | 语言 |
|------|------|
| [cn/DesktopManagerSpec.md](cn/DesktopManagerSpec.md) / [en/DesktopManagerSpec.md](en/DesktopManagerSpec.md) | CN / EN |
| [cn/DesktopQA.md](cn/DesktopQA.md) | CN |
| [cn/AeroDesktopRuntime.md](cn/AeroDesktopRuntime.md) / [en/AeroDesktopRuntime.md](en/AeroDesktopRuntime.md) | CN / EN |
| [cn/AeroRendering.md](cn/AeroRendering.md) | CN |
| [cn/DpiDesktop.md](cn/DpiDesktop.md) | CN |
| [cn/DWM_NOTIFY_MODEL_NT61.md](cn/DWM_NOTIFY_MODEL_NT61.md) / [en/DWM_NOTIFY_MODEL_NT61.md](en/DWM_NOTIFY_MODEL_NT61.md) | CN / EN |
| [cn/SOFTWARE_COMPOSITOR_WDDM.md](cn/SOFTWARE_COMPOSITOR_WDDM.md) | CN |
| [cn/NT61_GRAPHICS_SCAFFOLD.md](cn/NT61_GRAPHICS_SCAFFOLD.md) / [en/NT61_GRAPHICS_SCAFFOLD.md](en/NT61_GRAPHICS_SCAFFOLD.md) | CN / EN |
| [cn/NT61_WINMSG_API_TRACKER.md](cn/NT61_WINMSG_API_TRACKER.md) / [en/NT61_WINMSG_API_TRACKER.md](en/NT61_WINMSG_API_TRACKER.md) | CN / EN |
| [cn/Win32kArchitectureNotes.md](cn/Win32kArchitectureNotes.md) | CN |
| [cn/LPC_NT61_HANDSHAKE.md](cn/LPC_NT61_HANDSHAKE.md) / [en/LPC_NT61_HANDSHAKE.md](en/LPC_NT61_HANDSHAKE.md) | CN / EN |
| [cn/LPC_USER_SERVERS_CONTRACT.md](cn/LPC_USER_SERVERS_CONTRACT.md) / [en/LPC_USER_SERVERS_CONTRACT.md](en/LPC_USER_SERVERS_CONTRACT.md) | CN / EN |
| [cn/VirtioVirglMVP.md](cn/VirtioVirglMVP.md) | CN |

---

## PE、DLL 导出、合规资源

| 文件 | 语言 |
|------|------|
| [cn/CORE_DLL_PE_EXPORT_STRATEGY.md](cn/CORE_DLL_PE_EXPORT_STRATEGY.md) | CN |
| [cn/DWMAPI_PE_EXPORT_STRATEGY.md](cn/DWMAPI_PE_EXPORT_STRATEGY.md) | CN |
| [cn/Assets.md](cn/Assets.md) | CN |

---

## Shell、内置应用、图标（en/cn 成对或主文档标注）

| 文件 | 语言 |
|------|------|
| [en/NT61_ShellIcons.md](en/NT61_ShellIcons.md) / [cn/NT61_ShellIcons.md](cn/NT61_ShellIcons.md) | EN / CN |
| [en/BuiltinApps_NT61_Roadmap.md](en/BuiltinApps_NT61_Roadmap.md) / [cn/BuiltinApps_NT61_Roadmap.md](cn/BuiltinApps_NT61_Roadmap.md) | EN / CN |
| [en/LPC_LARGE_MESSAGE.md](en/LPC_LARGE_MESSAGE.md) | EN |
| [en/LPC_NT61_CALL_CHAIN.md](en/LPC_NT61_CALL_CHAIN.md) | EN |

---

## 法律与来源

| 文件 | 语言 |
|------|------|
| [en/COPYRIGHT_AND_SOURCES.md](en/COPYRIGHT_AND_SOURCES.md) / [cn/COPYRIGHT_AND_SOURCES.md](cn/COPYRIGHT_AND_SOURCES.md) | EN / CN |

|## cn-only 说明

NT 6.1 深度技术文档以 **简体中文** 为主维护；英文读者请从 [README.md](README.md) → [cn/README.md](cn/README.md) 或本索引进入。