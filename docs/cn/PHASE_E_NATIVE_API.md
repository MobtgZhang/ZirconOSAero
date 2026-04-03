# 阶段 E：Native API 深度补全（验收边界）

本文件冻结 **阶段 E** 的做/不做范围，与 [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) Phase K7 及 [NT61_FULL_API_BACKLOG.md](NT61_FULL_API_BACKLOG.md) 交叉引用。

**命名说明**：本「阶段 E」仅指 **Native / ntdll / SSDT 扩面**；≠ [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md) 中 **Phase E — Shell**。**全文 Phase 对照**：[README.md](README.md) 第二节。

**长期不在本阶段一次性交付**：全量 `SYSTEM_INFORMATION_CLASS`、完整 Ob 命名空间、生产级 ALPC、商业 `ntdll.dll` 全量等价。

**本仓库阶段 E 验收原则**：以 **可测子集 PR** 为单位；每条新 syscall 须在 [SSDT_Roadmap.md](SSDT_Roadmap.md) / [SyscallABI.md](SyscallABI.md) 有说明；`zig build test` 绿（含 `ssdt_stub_parity`、`nt61_full_api_backlog_anchors_host`）。

## E0 — 完成定义与门禁

| ID | 任务 | 验收 |
|----|------|------|
| E0.1 | 本文件 + 契约矩阵 §3 / §8 摘要 | 矩阵与 MVT 可链接 |
| E0.2 | 新 syscall：`ssdt_nt61` 注释来源；主机/内核测试 | K7.1 |
| E0.3 | `tests/nt61_full_api_backlog_anchors_host.zig` 每节真断言 | CI |

## E1 — 执行体与同步

| ID | 任务 |
|----|------|
| E1.1 | `NtAlertThread` / 可告警与 wait/APC 文档一致 — **Partial**：`alert_pending` → `STATUS_ALERTED`（先于 `STATUS_USER_APC`） |
| E1.2 | `NtDelayExecution` 绝对到期 — **Partial**：正间隔无单调换算 → 立即 `SUCCESS`（见 TimerPrecisionRoadmap） |
| E1.3 | 互斥/信号量句柄池 + `ObjectHeader` 与 `wait.zig` |
| E1.4 | `NtWaitForMultipleObjects`：`WaitAll` — **Partial**：调度关协作式；调度开 `STATUS_NOT_IMPLEMENTED` |

## E2 — 虚拟内存

| ID | 任务 |
|----|------|
| E2.1 | `NtLockVirtualMemory` / `NtUnlockVirtualMemory` 桩或最小实现 |
| E2.2 | `NtReadVirtualMemory` / `NtWriteVirtualMemory` 跨进程 probe / 错误码 |
| E2.3 | `NtProtectVirtualMemory` / `NtQueryVirtualMemory` 与 VAD/PTE 审计（持续） |

## E3 — I/O 与设备

| ID | 任务 |
|----|------|
| E3.1 | `NtDeviceIoControlFile` 子集路由（如 RTC IOCTL） |
| E3.2 | 命名管道 / 邮件槽：`NtCreateNamedPipeFile` → `STATUS_NOT_IMPLEMENTED`（邮件槽仍为路线图） |

## E4 — 对象与命名空间

| ID | 任务 |
|----|------|
| E4.1 | `NtOpenDirectoryObject` / `NtQueryDirectoryObject` 子集 |
| E4.2 | `NtDuplicateObject` / `NtQueryObject` 参数与访问掩码扩展 |
| E4.3 | 符号链接解析与 Ob 打开路径统一（持续） |

## E5 — 进程与线程

| ID | 任务 |
|----|------|
| E5.1 | `NtCreateProcess` / `NtCreateProcessEx` 与 `NtCreateUserProcess` 区分；用户创建路径见 [PHASE_F_PROCESS_CREATE.md](PHASE_F_PROCESS_CREATE.md) |
| E5.2 | `NtQuery/SetInformationProcess` 未实现 class 明确返回码 |
| E5.3 | `NtQueryInformationThread` / `NtSuspendThread` / `NtResumeThread` / `NtOpenProcess` — **Suspend/Resume** 仍为计数桩（矩阵诚实项） |

## E6 — 安全

| ID | 任务 |
|----|------|
| E6.1 | `NtOpenProcessToken` / `NtQueryInformationToken` 信息类扩展 |
| E6.2 | `SeAccessCheck` 与句柄 `DesiredAccess` 文档化 |

## E7 — LPC

| ID | 任务 |
|----|------|
| E7.1 | `NtReplyWaitReceivePort` 族与 `port.zig` / 子系统行为一致 |
| E7.2 | 大消息 / Section 视图：设计 + 桩 |

## E8 — 注册表

| ID | 任务 |
|----|------|
| E8.1 | `NtOpenKeyEx`、事务 API：Stub 或子集 |
| E8.2 | Hive 持久化与 `registry/` 路线图（见 NT61_KERNEL_TODO K7.3） |

## E9 — 系统信息

| ID | 任务 |
|----|------|
| E9.1 | `NtQuerySystemInformation` 多 class、`ReturnLength` |
| E9.2 | `NtSetSystemInformation` 允许范围 + 未实现返回码 |

## E10 — PE / WOW64

| ID | 任务 |
|----|------|
| E10.1 | PE 延迟加载 / 绑定与 loader 里程碑一致 |
| E10.2 | WOW64 x86 SSDT 与 x64 命名空间对照 — **进展**：[`x64_semantic_alias.zig`](../../src/subsystems/win32/wow64/x64_semantic_alias.zig)、[PHASE_G_WOW64.md](PHASE_G_WOW64.md)、**wow64_x64_semantic_alias_host** |

## E11 — Win32k 折叠槽

| ID | 任务 |
|----|------|
| E11.1 | `NtUser*` 折叠策略与 `ssdt_nt61` / SyscallABI 同步 |

## 与当前实现同步的扫尾注记（E1 / E3 / E5）

- **E2.3**：`NtProtectVirtualMemory` / `NtQueryVirtualMemory` 与 VAD/PTE 的持续审计见 [NT61_VirtualMemory_ABI_Notes.md](NT61_VirtualMemory_ABI_Notes.md)、契约矩阵 §3。
- **E4.2 / E4.3**：`NtDuplicateObject` / `NtQueryObject` 与 `se/token` 访问掩码、`normalizeNtObjectPathResolveSymlinks` 与 Ob 打开路径 — 以 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §3 与 `zircon_host_ob_test` 为锚点。
- **E6–E8 / E10–E11**：信息类扩展、ALPC 大消息、hive、PE delay-load、WOW64 折叠槽等仍以本文件各节 + `NT61_KERNEL_TODO.md` K7 为滚动清单；WOW64 专文与双表维护见 [PHASE_G_WOW64.md](PHASE_G_WOW64.md)。

## 建议实施顺序

1. E0 + E9.1  
2. E5.2–E5.3  
3. E1.3–E1.4  
4. E2 / E4 / E7 / E8 按优先级并行  
5. E10–E11 绑定 PE / WOW64 里程碑  
