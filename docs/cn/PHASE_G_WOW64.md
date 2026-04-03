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
| x86→x64 同名映射 | [`x64_semantic_alias.zig`](../../src/subsystems/win32/wow64/x64_semantic_alias.zig) | `x64SsdtIndexForWin7Sp1X86`（**不**声称封送完整） |
| Thunk 入口 | [`thunk.zig`](../../src/subsystems/win32/wow64/thunk.zig) | `translateSyscall32to64`、指针/句柄转换 |
| 重定向占位 | [`redirect.zig`](../../src/subsystems/win32/wow64/redirect.zig) | System32↔SysWOW64、WOW6432Node 占位 |
| 进程演示 | [`wow64.zig`](../../src/subsystems/win32/wow64.zig) | `Wow64Process`、`last_x64_ssdt_alias` |
| PE32 加载策略（与 E10 共用结论） | [`pe.zig`](../../src/loader/pe.zig) | delay-load / bound 等诚实边界见 [PHASE_E_NATIVE_API.md](PHASE_E_NATIVE_API.md) E10 |

## 调用约定与文档交叉引用

- AMD64 `syscall` 寄存器约定、折叠 Win32k 槽位： [SyscallABI.md](SyscallABI.md)。
- 契约矩阵 WOW64 行： [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §9.1（与本文 **互链**）。
- 用户进程创建与 WOW64 子进程诚实边界： [PHASE_F_PROCESS_CREATE.md](PHASE_F_PROCESS_CREATE.md)。
- 桌面阶段 4 硬件/WOW64 范围： [PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](PHASE4_HARDWARE_SYSTEM_INTEGRATION.md)。

## 验收与测试

| 门禁 | 说明 |
|------|------|
| `zig build test` | **wow64_ssdt_x86**、**ssdt_x64_x86_namespace**、**wow64_x64_semantic_alias_host**、**wow64_redirect_host**、**phase4_host_anchors**（LPC 族与 x86 号一致）等 |
| `translateSyscall32to64` | 对 stub 列表返回 `STATUS_SUCCESS`；有 x64 对照的服务写入 `Wow64Process.last_x64_ssdt_alias`；`NtTerminateThread` 在 `ssdt_nt61` 未收录时别名为 `null`，仍可由 stub 列表返回演示成功 |
| NTSTATUS | 与 [`ntdll.zig`](../../src/libs/ntdll.zig) 常量一致；未实现路径 `STATUS_NOT_IMPLEMENTED` |

## G1–G2 维护约定

- 扩展 `wow64SyscallStubReturnsSuccess` 时：**同步** `x64_semantic_alias.x64SsdtIndexForWin7Sp1X86`（若 `ssdt_nt61` 已有同名常量）、**ssdt_x64_x86_namespace** / **wow64_x64_semantic_alias_host** 断言、矩阵 §9.1。
- win32k 折叠槽与 x86 原生 win32k 号**不同命名空间** — 见 `ssdt_x86_win7_sp1.Win32kNtUserPostMessage_x86_index4111` 与 `ssdt_nt61.NtUserPostMessage` 注释。
