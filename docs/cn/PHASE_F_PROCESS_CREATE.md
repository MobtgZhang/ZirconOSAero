<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->

# 阶段 F：用户进程创建路径（`NtCreateUserProcess`）

> **命名区分**：本文专指 **用户进程创建路径**（`NtCreateUserProcess` / SSDT **0xAA**）；≠ [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md)「Phase F — 集成」。**全文 Phase 对照**：[README.md](README.md) 第二节。

## 参考（公开文档）

- [NtCreateUserProcess](https://learn.microsoft.com/windows/win32/api/winternl/nf-winl-ntcreateuserprocess)（行为级；本仓库参数块为 **ZOA 简化 ABI**）
- [PROCESS_BASIC_INFORMATION](https://learn.microsoft.com/windows/win32/api/winternl/ns-winternl-process_basic_information)
- 本仓库：[PROCESS_NT61.md](PROCESS_NT61.md)、[SyscallABI.md](SyscallABI.md)、[NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)

## ZOA 子集：已实现

| 环节 | 说明 |
|------|------|
| Syscall **0xAA** | `syscall_nt_extras.dispatchNtCreateUserProcess`：`R10` → `ZirconCreateUserProcessArgs`（见 `syscall_abi.zig` 注释） |
| 参数探测 | `probeUserMemory` 参数块与输出 `HANDLE` 槽；`UNICODE_STRING` 映像路径 → 窄字节路径 |
| 进程对象 | `process.createProcess`：地址空间、kuser、`parent_pid`、**令牌浅拷贝**（父 `security_token`） |
| PE 桩 | `pe_loader.createProcessImage` + `resolveImports`；失败返回 `STATUS_ENTRYPOINT_NOT_FOUND`（0xC0000139）等 |
| 初始线程 | `scheduler.createThread(entry, child.pid)`；`PsThreadObject` 供线程句柄 |
| 句柄 | 父进程句柄表：`ObjectType.process` / `.thread` |
| `NtCreateProcess` / `NtCreateProcessEx` | 旧桩仅分配进程槽；**不**映射映像；与本文路径区分见 `ntdll.zig` 注释 |

## 参数块 `ZirconCreateUserProcessArgs`（用户态布局）

```text
offset 0:  image_path_unicode  u64   UNICODE_STRING*
         process_handle_out    u64   PHANDLE（可写）
         thread_handle_out     u64   PHANDLE（可写；0 = 不要线程句柄）
         creation_flags        u32   保留/透传（当前忽略）
         reserved              u32
```

## 已知差距（诚实边界）

- **映像与 CR3**：`pe_loader.loadImage` 为全局 `LoadedImage` 元数据桩，**未**将节区映射到子进程 `AddressSpace`；调度器线程入口为 **元数据中的 RIP**，与真实 NT 用户态执行模型不同。
- **PEB/TEB**：子进程 `Process.peb_address` 仍为 **0**（用户 VA 映射未接线）；`NtQueryInformationProcess` 的 `peb_base_address` 与此一致。
- **CSRSS / 子系统**：无完整子系统握手、无作业对象、无调试对象。
- **WOW64**：32 位子进程 / SysWOW64 为 **Partial** 路线图；验收边界与测试见 [PHASE_G_WOW64.md](PHASE_G_WOW64.md)（阶段 G 与本文「阶段 F」区分）。

## 验收 NTSTATUS（节选）

| 值 | 含义 |
|----|------|
| `STATUS_SUCCESS` | 创建子集成功 |
| `STATUS_INVALID_PARAMETER` | 参数块/路径非法 |
| `STATUS_ACCESS_VIOLATION` | 探测失败 |
| `STATUS_NO_MEMORY` | 进程/映像/线程槽耗尽 |
| `STATUS_ENTRYPOINT_NOT_FOUND` | 导入未全部解析（0xC0000139） |
| `STATUS_INSUFFICIENT_RESOURCES` | 句柄表满等 |

## 验证

- **F-VERIFY**：`syscall.zig` 中 `ssdt.NtCreateUserProcess` → `syscall_nt_extras.dispatchNtCreateUserProcess`；回滚与 NTSTATUS 以本文「ZOA 子集」表为准。
- `zig build test`（含 `ssdt_stub_parity`、`NtCreateUserProcess` 号与 `ntdll_syscall_win64` 一致）
- `bash scripts/verify-compliance.sh`

**F-DEEP（可选 PR）**：节区映射到子进程 `AddressSpace`、用户 VA PEB/TEB 与 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §9 及 [PHASE_G_WOW64.md](PHASE_G_WOW64.md) 诚实登记 — 未做则保持矩阵 **Partial**。
