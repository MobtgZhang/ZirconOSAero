# ZirconOSAero：NT 6.1 内核实现详细待办清单（Clean-room）

本页为内核模式实现的**分阶段跟踪清单**，与 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 交叉引用。实现须遵守 clean-room：**仅** Microsoft Learn、WDK 公开文档与硬件规范；禁止 Windows/ReactOS/Wine 源码。

**与「实施计划 Phase A–K」对齐**：里程碑式扩展（闸门、Mm、调度等待、I/O 闭环、Ob、Ps、LPC、Se、SSDT 模块化、HAL/存储占位、完整 API backlog）见 [NT61_FULL_API_BACKLOG.md](NT61_FULL_API_BACKLOG.md) 与契约矩阵 §3.1；代码落地仍以本页 **K0–K8** 编号为主便于 PR 引用。

**与桌面 / LPC / 显示栈收敛对齐**：在 **不缩小 K1–K8 范围** 的前提下，LPC、`user32`、显示栈的收敛与契约常量见 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §4.1、`src/config/dwm_nt61_api_contract.zig`、MVT 中 **dwm_zorder_nt61_host** / **csr_lpc_policy_host**；全栈 Aero 用户态仍属 [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md)。

## 范围

- **在内**：`src/mm`、`src/ke`、`src/hal`、`src/arch`、syscall 分发、`src/io`、`src/ob`、`src/se`、`src/lpc`、`src/ps` 内核对象路径、`src/fs` 与 IRP 桥接。
- **不在此清单展开**：完整 Win32 子系统、Aero 壳、完整 WDDM — 见 [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md)。

## Phase K0 — 流程与验证（贯穿全程）

**PR 合并前勾选清单（人类可读）**：[NT61_PR_GATES.md](NT61_PR_GATES.md)。

| ID | 任务 | 验收 |
|----|------|------|
| K0.1 | 每个里程碑 PR 同步更新 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 对应行 | 与矩阵 §8 三向跟踪一致 |
| K0.2 | 新增能力扩展 [MVT_NT61.md](MVT_NT61.md) 或 `tests/` | `zig build test` 与 CI 绿 |
| K0.3 | syscall/驱动入口注释含 Learn/WDK URL 与简化假设 | 代码审查 |
| K0.4 | 提交前 `bash scripts/verify-compliance.sh` | CI Compliance 步骤 |

## Phase K1 — 内存管理、探测与进程隔离

| ID | 任务 | 主要路径 |
|----|------|----------|
| K1.1 | 物理帧与伙伴/连续页全路径接线 | `src/mm/frame.zig`, `buddy.zig`, `phys_buddy.zig` |
| K1.2 | 非分页/分页池语义与 IRQL 注释与 WDK 对齐 | `src/mm/pool.zig`, [MM_HEAP_POOL_SLAB.md](MM_HEAP_POOL_SLAB.md) |
| K1.3 | Slab/堆统计与不变量 | `slab.zig`, `heap.zig` |
| K1.4 | VMA 释放与泄漏回归 | `vm.zig`, `arch/x86_64/paging.zig` |
| K1.5 | syscall 用户缓冲 probe 审计 | `probe.zig`, `syscall.zig` |
| K1.6 | 节区对象与 VM 生命周期 | [MM_Section_Roadmap.md](MM_Section_Roadmap.md), `section.zig` |
| K1.7 | MDL 最小抽象（DMA 前置） | `src/mm/mdl.zig` |

## Phase K2 — 调度、定时器、SMP

| ID | 任务 | 主要路径 |
|----|------|----------|
| K2.1 | CR3 切换与进程销毁顺序 | `src/ke/scheduler.zig` |
| K2.2 | 调度模型文档与可选 32 级优先级 | [SCHEDULER_API.md](SCHEDULER_API.md) |
| K2.3 | HPET/单调时钟接计时 | [TimerPrecisionRoadmap.md](TimerPrecisionRoadmap.md), `hal/x86_64/hpet.zig` |
| K2.4 | AP INIT-SIPI-SIPI 实路径 | `ap_entry.zig`, `madt.zig` |
| K2.5 | TLB IPI 或可证 BSP 策略 | `tlb_broadcast.zig` |
| K2.6 | 每 CPU 就绪队列与 `home_cpu` | `percpu_sched.zig` |

## Phase K3 — HAL：ACPI、PCIe、中断

| ID | 任务 | 主要路径 |
|----|------|----------|
| K3.1 | ACPI 表遍历与错误路径 | `acpi_pci_early.zig`, `multiboot2_parse.zig` |
| K3.2 | ECAM 枚举扩展 | `ecam_layout.zig` |
| K3.3 | IOAPIC 与 IRQ 路由 | `hal/x86_64/` |
| K3.4 | AML 解释器（独立里程碑） | ACPI spec，延后项 |

## Phase K4 — I/O 管理器、IRP、PnP/电源

| ID | 任务 | 主要路径 |
|----|------|----------|
| K4.1 | 设备栈与设备扩展 | `src/io/io.zig` |
| K4.2 | IRP 向下传递与完成例程 | `io.zig`, `tests/io_irp_host.zig` |
| K4.3 | PnP/Power IRP 子集 | [DriverMilestones_NT61.md](DriverMilestones_NT61.md) |
| K4.4 | IRQL/DPC 文档化 | `src/ke/dpc.zig` |

## Phase K5 — 内核态总线驱动

| ID | 任务 | 文档 |
|----|------|------|
| K5.1 | XHCI + HID（QEMU） | [HAL_USB_NET_ROADMAP.md](HAL_USB_NET_ROADMAP.md) |
| K5.2 | AHCI 或 NVMe | [STORAGE_IO_ROADMAP.md](STORAGE_IO_ROADMAP.md) |
| K5.3 | ARP/IPv4/UDP 扩展 | 同上 |

## Phase K6 — OB、SE、LPC

| ID | 任务 | 主要路径 |
|----|------|----------|
| K6.1 | 命名空间与符号链接子集 | `ob/object.zig` |
| K6.2 | 句柄表 teardown | `ob/` |
| K6.3 | ACL/模拟 | `se/token.zig` |
| K6.4 | LPC 与 csrss 契约 | `lpc/port.zig`, [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) |

## Phase K7 — SSDT 与 Native 内核语义

| ID | 任务 | 主要路径 |
|----|------|----------|
| K7.1 | SSDT 版本与 ntdll/syscall 双端 | `ssdt_nt61.zig`, [SSDT_Roadmap.md](SSDT_Roadmap.md) |
| K7.2 | 虚拟内存与系统信息类对齐 | `syscall.zig`, [NT61_VirtualMemory_ABI_Notes.md](NT61_VirtualMemory_ABI_Notes.md) |
| K7.3 | 注册表内存树与 hive 分阶段 | 路线图 |

## Phase K8 — 文件系统内核层

| ID | 任务 | 主要路径 |
|----|------|----------|
| K8.1 | NTFS/FAT 边界与错误码 | `src/fs/` |
| K8.2 | VFS–IRP 桥接与共享访问标志 | `vfs.zig` |

## 执行顺序建议

1. K1 + K0 打底。  
2. K2.1–K2.3 与 K3.1–K3.3 可并行；K2.4–K2.6 建议在 K1.4/K2.1 稳定后加强。  
3. K4 → K5 → K6–K7；K8 长期并行。

## Phase 2–3 并行（GUI 稳定 / 验证闸门）

下列项与桌面栈、MVT、CI 交叉引用；**不替代** K1–K8 全量，但阶段 2/3 应持续勾选。

| 跟踪项 | 状态 | 参考 |
|--------|------|------|
| 方案 A Present 契约与脏区 API | 已落地初版 | [DesktopManagerSpec.md](DesktopManagerSpec.md) §1.1、`display.submitCompositorPresentHints` |
| LPC 单一真源 + 策略常量 | 已强化 | `subsystem.zig`、`csr_lpc_policy.zig`、`nt61_dual_track_host` |
| 跨 band `SetWindowPos` | 已落地 | `user32.placeHwndAboveInsertAfter`、`dwm_zorder_nt61_host` |
| 多监视器 / DPI 数据模型 | 已落地初版（单 GOP） | `framebuffer.MonitorLayoutNt61`、`multimon_dpi_nt61_host` |
| 合成 full vs partial 计数 | 已落地 | `display.getDesktopComposeTelemetry` |
| K6.3 活动桌面访问 | 已落地子集 | `seAccessActiveDesktopForWin32k`、`subsystem` LPC GUI |
| aarch64 + desktop-full CI | 已加 | `.github/workflows/ci.yml` |
| 性能基线脚本 | 已加 | `scripts/qemu_desktop_perf_baseline.sh` |
| K1–K8 纵深 | **并行长线** | 上表 Phase K1–K8 |

## 维护

更新本清单时同步 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §7 链接与根 README 若涉及对外完成度表述。

**近期 ABI 落地**（与 [NT61_FULL_API_BACKLOG.md](NT61_FULL_API_BACKLOG.md)「实现检查点」一致）：`KUSER_SHARED_DATA` 进程映射、`TEB` x64 `LastErrorValue` 偏移断言、`kernelbase` 分层、合成 `ntdll` 基址调整 — 见 `src/mm/kuser_shared.zig`、`src/sdk/teb_nt61_x64.zig`、`src/libs/kernelbase.zig`、`tests/nt61_abi_layout_host`。
