# NT 6.1 完整 Native / Win32 API 能力 backlog（与「基础迭代」分离）

本文件列出 **长期目标**：在 clean-room 前提下对齐 Microsoft 公开文档中的 **NT 6.1 全量 API 面**（含后续 Win32 子系统、WOW64、注册表全类等）。**当前工程交付**仍以 [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) 的 K0–K8 与 [MVT_NT61.md](MVT_NT61.md) 为闸门；本 backlog **不**表示已实现。**与契约矩阵 / API 骨架表分工**：[DOCS_MAINTAINERS.md](../DOCS_MAINTAINERS.md)。

**Phase 7 分节 PR**：`zig build test` → **nt61_full_api_backlog_anchors_host**（每节至少一条与 `ssdt_nt61` / 常量同源的**真断言**；阶段 E 总表见 [PHASE_E_NATIVE_API.md](PHASE_E_NATIVE_API.md)）。

**版权**：仅 MSDN / WDK / 硬件与 VirtIO 等公开规范；禁止 Windows/ReactOS/Wine 源码。

## 1. 执行体与同步（Ke / Nt*）

- `NtAlertThread`、`NtDelayExecution`、`NtSuspendThread`、`NtResumeThread` 等。（`NtDelayExecution`：内核已接 SSDT `0x31`，负间隔为 `yield` 近似；精确计时见 [TimerPrecisionRoadmap.md](TimerPrecisionRoadmap.md)。）
- 互斥体、信号量、定时器、多对象等待的完整语义与 IRQL 文档化行为。

## 2. 虚拟内存（Mm / Nt*）

- `NtProtectVirtualMemory`、`NtLockVirtualMemory`、`NtReadVirtualMemory` / `NtWriteVirtualMemory`（跨进程）、AWE 相关（若产品范围包含）。

## 3. I/O 与设备（Io / Nt*）

- `NtDeviceIoControlFile`、`FsRtl`/`Cc` 缓存语义扩展。
- 命名管道、邮件槽、完成端口（IOCP）子集。

## 4. 对象与命名空间（Ob）

- 完整目录对象、符号链接解析、`NtOpen*` 族与句柄属性标志矩阵。

## 5. 进程与线程（Ps）

- `NtCreateProcessEx` / 作业对象、调试对象、完整 PEB/TEB 与 WOW64 上下文。

## 6. 安全（Se）

- 完整 ACL/SACL 解析、`SeAccessCheck` 与审计策略；模拟令牌级别矩阵。

## 7. LPC / ALPC

- 完整 `NtReplyWaitReceivePort` 族、大消息与 Section 视图绑定的生产路径。

## 8. 注册表（Cm / Nt*）

- `NtOpenKeyEx`、`NtEnumerateKey`、`NtSetValueKey` 等 hive 持久化与事务（按 NT 6.1 文档边界）。

## 9. 系统信息与调试（Nt* / Kd）

- `NtQuerySystemInformation` / `NtSetSystemInformation` 全 `SYSTEM_INFORMATION_CLASS` 分优先级落地。
- 内核调试与性能剖析 API（若纳入产品范围）。

## 10. 用户态二进制兼容（加载器 / PE）

- PE 导出表、导入表绑定、延迟加载；与真实 `ntdll.dll` 二进制的 ABI 对齐为独立里程碑（见 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) Win32 边界说明）。

## 实现检查点（与分阶段计划同步）

- **Phase0–1（闸门 + ABI）**：`bash scripts/verify-compliance.sh`；`zig build test` 含 **nt61_abi_layout_host**；`KUSER_SHARED_DATA` 映射与 `TEB` 偏移见 `src/mm/kuser_shared.zig`、`src/sdk/teb_nt61_x64.zig`。
- **Phase5–7（Native 扩面）**：按上文章节逐 PR 扩展 `Nt*` / 注册表 / LPC，并同步 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 与 `tests/`。
- **Phase8（win32k）**：[`src/subsystems/win32k/`](../../src/subsystems/win32k/)（含 `atoms.zig` 占位）与 [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md)。

## 11. NtUser* / win32k SSDT 波次（x64 Win7 SP1 公开索引）

索引来源为 **公开 syscall 枚举**（如 j00ru `windows-syscalls`）；实现须 clean-room，仅名称与编号对齐。

| 波次 | 服务（示例） | 公开索引（SP1 x64） | 状态 |
|------|----------------|---------------------|------|
| W5-A（已接线） | `NtUserGetMessage` | `0x58` | **SSDT 已接线 + 子集语义**（非完整 `user32`/`win32k` 等价 — 见契约矩阵 §5、[NT61_WINMSG_API_TRACKER.md](NT61_WINMSG_API_TRACKER.md)） |
| W5-A | `NtUserPeekMessage` | `0x59` | 同上 |
| W5-B（下一批） | `NtUserPostMessage` / `NtUserSendMessage` / `NtUserSetWindowPos` 等 | 查表后逐条填入 `ssdt_nt61.zig` | Planned |
| WOW64 | 同上名称的 x86 表项 + x64 语义别名 | `wow64/ssdt_x86_win7_sp1.zig`、`wow64/x64_semantic_alias.zig`；[PHASE_G_WOW64.md](PHASE_G_WOW64.md) | Partial |

详细消息/API 与测试 ID 的对应表见 [NT61_WINMSG_API_TRACKER.md](NT61_WINMSG_API_TRACKER.md)。

## 维护

新增条目时在本文件追加节或表行；**契约矩阵** §3 / §8 仅链接摘要，避免与 `src/` 实现状态脱节。
