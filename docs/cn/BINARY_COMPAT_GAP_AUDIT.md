# 二进制兼容导向缺口审计（K1–K8 + 契约矩阵）

本页是 [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) K1–K8 与 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §0 / §8 的 **Partial / Stub** 汇总，按对「稳定性 → 可加载 PE / 导出 ABI」的影响排序。**不**编辑 `.cursor/plans/` 内计划文件；本审计随 PR 更新。

## 优先级说明

| 优先级 | 含义 |
|--------|------|
| **P0** | 多核 / TLB / 池 OOM 等 correctness 或数据损坏风险 |
| **P1** | I/O、安全、LPC 与用户态壳主路径 |
| **P2** | SSDT/系统信息、NTFS、hive、WOW64 深度 |
| **P3** | 文档化占位、CI 烟测、导出清单 |

## 矩阵（2026-04 快照）

| 领域 | 契约 / TODO 锚点 | 状态 | 优先级 | 主要路径与备注 |
|------|------------------|------|--------|----------------|
| SMP 唤醒 | K2.4、矩阵 §0 AP 行 | Partial | P0 | `lapic_smp.zig` INIT + **SIPI×2** + 低 1MiB 实模式跳板（`0x8000` `EB FE` 自旋）；长模式 AP + per-CPU `scheduler.tick` 仍为后续 |
| TLB | K2.5、矩阵 §0 | Partial | P0 | `tlb_broadcast.zig`：多核时 **仅 BSP 本地刷新** + 计数；IPI shootdown 未接线；页表更新路径已 `noteUserMappingInvalidatedSmp` |
| PagedPool | K1.2 | Partial | P0 | `pool.zig`：与 NonPaged 共用后备；**无换出**；`notePagedPoolTrimPlaceholder` 占位统计 |
| 用户探测 / 池 IRQL | K1.5 / K1 | Partial | P1 | `probe.zig`、`pool.zig` 注释 |
| IO PnP/Power | K4.1–K4.3 | Partial | P1 | `io.zig`：`IoForwardIrpToNextDevice`、`dispatchIrpThroughStack`；VFS 卷 IRP 桩 |
| VFS 共享 | K8.2 | Partial | P1 | `vfs.zig`：`FILE_SHARE_*` 子集冲突检测（同路径已打开句柄） |
| Ob 符号链接 | K6.1 | Partial | P1 | `object.zig`：**多跳**（最多 8）`normalizeNtObjectPathResolveSymlinks` |
| Se DACL | K6.3 | Partial | P1 | `token.zig`：`seAccessCheckWithDacl` 简化（无 DACL → 允许掩码语义占位） |
| LPC / csrss | K6.4 | Partial | P1 | `port.zig`：`handshake_version = 2`（大消息/超时字段单一真源演进）；[LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) |
| SSDT / NtQuerySystemInformation | K7.1–K7.2 | Partial | P2 | `ssdt_nt61.zig`、`ntdll.zig`；`SystemVersionInformation` 布局 284 字节锚点测试 |
| PE 加载 | 阶段 4 / API 矩阵 | Partial | P2 | `pe.zig`：按序号导出解析、`validatePeLoadPolicy`（TLS/delay import 非空 → 明确 `LoadStatus`）、`loadStatusToNtStatus` |
| 导出清单 | 矩阵 §0 脚注 | Partial | P3 | `ntdll_kernel32_user32_nt61_abi_inventory.zig` + 策略短文 |
| WOW64 | §9.1 | Partial | P2 | `thunk.zig` ↔ `ssdt_x86_win7_sp1.zig` 公开 Win7 SP1 x86 号子集 |
| 最小 PE CI | MVT | Partial | P3 | `zig build minimal-pe-nt61` → `zig-out/bin/minimal_pe/`；QEMU 可选 |
| 文档立场 | README / API 矩阵 | Done 维护 | P3 | 二进制兼容 = 自研 DLL + 公开 ABI **子集** + PE 策略；**非**替换 system32 闭源 DLL |

## 回归与闸门

- 主机：`zig build test`（含新增 `lpc_handshake_version_host`、`nt61_os_version_layout_host`、`ntdll_k32_u32_abi_inventory_host`、`wow64_ssdt_x86` 等）。
- 合规：`bash scripts/verify-compliance.sh`。
- 可选：`bash scripts/ci-qemu-smoke.sh`；最小 PE 构建：`zig build minimal-pe-nt61`。
