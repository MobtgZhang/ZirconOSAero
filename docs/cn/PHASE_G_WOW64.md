<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->

# 阶段 G：WOW64 / SysWOW64 行为子集（ZirconOSAero）

> **命名区分**：本文专指 **WOW64 可测子集**（x86/x64 服务号、thunk、指针/句柄规则）；≠ [Roadmap.md](Roadmap.md)「Phase 11 — WOW64 + 音频」全文。**Phase 命名总索引**：[README.md](README.md) 第二节。

## 知识来源与边界

- 行为级描述以 [Microsoft Learn](https://learn.microsoft.com/) / WDK 公开文档与本仓库 [docs/cn](README.md) 契约为准。
- **x86 / x64 服务号**对照以公开数据集为准（如 j00ru [windows-syscalls](https://github.com/j00ru/windows-syscalls) `nt-per-system.json`）；代码中注明 URL/数据集名，**不**抄闭源表。
- **非目标**：与商业 Windows 7 SysWOW64 **逐行为等价**；完整参数封送、商业 ntdll 二进制兼容、完整文件系统/注册表重定向。

## 实现锚点（代码）

| 组件 | 路径 | 说明 |
|------|------|------|
| x86 Win7 SP1 子集 | [`ssdt_x86_win7_sp1.zig`](../../src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig) | 原生 32 位服务号；`wow64SyscallStubReturnsSuccess` |
| x64 SSDT 子集 | [`ssdt_nt61.zig`](../../src/arch/x86_64/ssdt_nt61.zig) | 内核/ntdll 共用索引真源之一 |
| x86→x64 同名映射 | [`x64_semantic_alias.zig`](../../src/subsystems/win32/wow64/x64_semantic_alias.zig) | `x64SsdtIndexForWin7Sp1X86`（**不**声称封送完整）；`NtTerminateThread` → `ssdt_nt61.NtTerminateThread`（**0x55**，与 j00ru x64 公开列 **0x51** 冲突说明见 `ssdt_nt61` 注释） |
| Thunk 入口 | [`thunk.zig`](../../src/subsystems/win32/wow64/thunk.zig) | `translateSyscall32to64` / `translateSyscall32to64WithArgs`、`marshal` 派发；x86 **win32k** 号（`≥0x1000`）显式 `STATUS_NOT_IMPLEMENTED` |
| 封送子集 | [`marshal.zig`](../../src/subsystems/win32/wow64/marshal.zig) | 见下表 **stdcall→封送**；未列出的 stub 仍演示 `STATUS_SUCCESS` |
| 重定向可测子集 | [`redirect.zig`](../../src/subsystems/win32/wow64/redirect.zig) | UTF-16LE `\System32\`→`\SysWOW64\`；窄路径 `\Registry\Machine\SOFTWARE\` 下插入 `Wow6432Node\`；`syscall.zig` / `ntdll`（`NtOpenKey`/`NtCreateKey`）接线 |
| 进程演示 | [`wow64.zig`](../../src/subsystems/win32/wow64.zig) | `Wow64Process`、`last_x64_ssdt_alias`；PEB32 版本字段来自 [`os_version.zig`](../../src/config/os_version.zig) |
| PE32 加载策略（与 E10 共用结论） | [`pe.zig`](../../src/loader/pe.zig) | delay-load / bound 等诚实边界见 [PHASE_E_NATIVE_API.md](PHASE_E_NATIVE_API.md) E10 |

## 双 PEB / TEB 布局与里程碑（G-B2 / F 协同）

- **PEB64 / TEB64**：x64 用户进程主线程由加载器与 `kuser_shared` / `teb_nt61_x64` 等路径约束；与 [PHASE_F_PROCESS_CREATE.md](PHASE_F_PROCESS_CREATE.md) 进程创建里程碑对齐。
- **PEB32 / TEB32**：`types.zig` 中 `extern` 子集 + comptime 偏移测试（Learn `PEB`/`TEB` 公开字段语义）；演示 VA `PEB32_DEFAULT_USER_VA` / `TEB32_DEFAULT_USER_VA`。
- **内核 `Process` 镜像**：`ps/process.zig` 的 `peb32_user_va` / `teb32_user_va` 与 `is_wow64` 由 `wow64.zig` 协同；`createWow64Process` 在 x86_64 上为 **PEB32/TEB32 各映射一页用户可写页** 并写入 `extern` 布局。**节区视图 / `NtAllocateVirtualMemory` 全路径 probe** 仍为 Partial，见契约矩阵 §9.1。

## stdcall（Win32 x86）实参序 → `marshal` / x64 `ntdll` 桩

以下为 **32 位 ntdll 常用 native** 在 stdcall 下 **自右向左压栈** 时，栈上从左到右（即 `args[0]` 起）与 x64 形参的对应关系；与 [`marshal.zig`](../../src/subsystems/win32/wow64/marshal.zig) 实现一致。公开调用约定概念见 [stdcall](https://learn.microsoft.com/cpp/cpp/stdcall)；x86 服务号见 j00ru `x86/json/nt-per-system.json`（Win7 SP1）。

| x86 服务（Win7 SP1） | stdcall 栈序 `args[0]…` | x64 / `ntdll` 调用 |
|----------------------|-------------------------|---------------------|
| `NtClose` | `Handle` | `NtClose(@as(u64, Handle))` |
| `NtWaitForSingleObject` | `Handle`, `Alertable`, `Timeout` | `Timeout==0` → `null`；否则用户 VA 须 ≤ `WOW64_MAX_ADDR`（`types.zig`），再 `NtWaitForSingleObject` |
| `NtTerminateProcess` | `ProcessHandle`, `ExitStatus` | `NtTerminateProcess(handle, @bitCast ExitStatus)` |
| `NtDelayExecution`（x86 **0x62**） | `Alertable`, `*LARGE_INTEGER` | 读用户 `interval`；再 `NtDelayExecution` |
| `NtAllocateVirtualMemory` | `Proc`, `**Base`, `ZeroBits`, `**RegionSize`, `AllocType`, `Protect` | 32 位指针扩址 + 回写 `Base`/`RegionSize`（低 32 位） |
| `NtFreeVirtualMemory` | `Proc`, `**Base`, `**RegionSize`, `FreeType` | 同上 |
| `NtDuplicateObject`（x86 **0x39**） | 七参 stdcall | `TargetHandle` 为用户侧 `*HANDLE32` 回写 |
| `NtReadFile` / `NtWriteFile` | 前七参含 `IoStatusBlock`、`Buffer`、`Length` | 内核临时 `IO_STATUS_BLOCK` 后 **拷回** 用户 IOSB（演示路径；完整 probe 与阶段 F 协同） |

**指针校验**：`userVaFromWow64Ptr32` / `convertPtr32to64` 对 `> WOW64_MAX_ADDR`（`0x7FFF_FFFF`）拒绝或归零，避免把内核高位误当用户指针。

## 调用约定与文档交叉引用

- AMD64 `syscall` 寄存器约定、折叠 Win32k 槽位： [SyscallABI.md](SyscallABI.md)。
- 契约矩阵 WOW64 行： [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §9.1（与本文 **互链**）。
- 用户进程创建与 WOW64 子进程诚实边界： [PHASE_F_PROCESS_CREATE.md](PHASE_F_PROCESS_CREATE.md)。
- 桌面阶段 4 硬件/WOW64 范围： [PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](PHASE4_HARDWARE_SYSTEM_INTEGRATION.md)。

## 验收与测试

| 门禁 | 说明 |
|------|------|
| `zig build test` | **wow64_ssdt_x86**、**ssdt_x64_x86_namespace**、**wow64_x64_semantic_alias_host**、**wow64_redirect_host**、**phase4_host_anchors**（LPC 族与 x86 号一致）等 |
| `translateSyscall32to64` / `WithArgs` | stub 命中后写 `last_x64_ssdt_alias`；**带参**路径经 `marshal` 调用 `ntdll`（`NtClose`、`NtWaitForSingleObject`、`NtTerminateProcess`、`NtDelayExecution` 等）；无参调用保持演示成功语义 |
| `Process` / PEB32 | [`process.zig`](../../src/ps/process.zig)：`is_wow64`、`peb32_user_va`、`teb32_user_va`；[`types.zig`](../../src/subsystems/win32/wow64/types.zig)：`PEB32`/`TEB32` 为 `extern` 子集布局；演示 VA `PEB32_DEFAULT_USER_VA` / `TEB32_DEFAULT_USER_VA`；`NtQueryInformationProcess`(`ProcessWow64Information`) |
| NTSTATUS | 与 [`ntdll.zig`](../../src/libs/ntdll.zig) 常量一致；win32k x86 号与未实现路径 `STATUS_NOT_IMPLEMENTED` |

## G1：用户态布局策略（与阶段 F 协同）

- **演示 VA**：`PEB32_DEFAULT_USER_VA`（`0x7FFDE000`）、`TEB32_DEFAULT_USER_VA`（`0x7FFDD000`）— 与公开 WOW64 文档常见区域同阶；**未**声称与商业映像逐字节一致。
- **进程表接线**：`wow64.createWow64Process` 在存在同 PID 的 `Process` 时调用 `process.attachWow64IfPresent`；真实子进程映射仍依赖阶段 F 节区/用户 VA（见 [PHASE_F_PROCESS_CREATE.md](PHASE_F_PROCESS_CREATE.md)）。

## G1–G2 维护约定

- 扩展 `wow64SyscallStubReturnsSuccess` 时：**同步** `x64_semantic_alias.x64SsdtIndexForWin7Sp1X86`（若 `ssdt_nt61` 已有同名常量）、**ssdt_x64_x86_namespace** / **wow64_x64_semantic_alias_host** 断言、矩阵 §9.1。
- win32k 折叠槽与 x86 原生 win32k 号**不同命名空间** — 见 `ssdt_x86_win7_sp1.Win32kNtUserPostMessage_x86_index4111` 与 `ssdt_nt61.NtUserPostMessage` 注释。
