# ZirconOSAero：NT 6.1 内核实现详细待办清单（Clean-room）

本页为内核模式 **K0–K8** 落地清单；**契约状态**见 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)，**验证映射**见 [MVT_NT61.md](MVT_NT61.md)，**文档职责**见 [DOCS_MAINTAINERS.md](../DOCS_MAINTAINERS.md)。实现须 clean-room：**仅** Microsoft Learn、WDK 与硬件规范；禁止 Windows/ReactOS/Wine 源码。

**基线引用**：阶段 A — 契约矩阵 §0、[MM_ALLOC_PATHS.md](MM_ALLOC_PATHS.md)、[VM_ISOLATION.md](VM_ISOLATION.md)；阶段 B — [SyscallABI.md](SyscallABI.md)、[SSDT_Roadmap.md](SSDT_Roadmap.md) 与 `ssdt_nt61.zig` / `syscall.zig`；阶段 C — [SCHEDULER_API.md](SCHEDULER_API.md)、契约矩阵 §2、`wait.zig` / `object.zig` / `scheduler.zig`。长期 API 面见 [NT61_FULL_API_BACKLOG.md](NT61_FULL_API_BACKLOG.md)（非本页交付范围）。桌面 / LPC / DWM 常量见契约矩阵 §4.1、`dwm_nt61_api_contract.zig`、[NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md)。二进制缺口见 [BINARY_COMPAT_GAP_AUDIT.md](BINARY_COMPAT_GAP_AUDIT.md)。

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
| K1.1 | PFN 链表（Free/Zeroed/Active）+ 位图连续分配；伙伴/连续页接线 | `src/mm/frame.zig`, `buddy.zig`, `phys_buddy.zig` |
| K1.2 | 池：`pool_zone.zig` + `lookaside.zig` + `pool.zig` / `ex_pool.zig`；IRQL 与 WDK 对齐 | [MM_HEAP_POOL_SLAB.md](MM_HEAP_POOL_SLAB.md), `src/mm/percpu_index.zig` |
| K1.3 | Slab/堆统计与不变量 | `slab.zig`, `heap.zig` |
| K1.4 | VMA 释放与泄漏回归；VAD AVL、惰性提交、文件视图 demand、`remapLeafPhysical` CoW、**`duplicateUserMappingsForFork`**（fork 子集） | `vm.zig`, `vad.zig`, `section.zig`, `arch/x86_64/paging.zig`；主机 **fork_cow_share_nt61_host** |
| K1.5 | syscall 用户缓冲 probe 审计 | `probe.zig`, `syscall.zig` |
| K1.6 | 节区对象与 VM 生命周期；**匿名 `PAGE_WRITECOPY`** 已按私有 RW 映射（fork CoW）；**文件后备 WRITECOPY** 仍 `STATUS_NOT_IMPLEMENTED` | [MM_Section_Roadmap.md](MM_Section_Roadmap.md), `section.zig`, [PFN_REFCOUNT_ROADMAP.md](PFN_REFCOUNT_ROADMAP.md) |
| K1.7 | MDL 最小抽象（DMA 前置） | `src/mm/mdl.zig` |

## Phase K2 — 调度、定时器、SMP

| ID | 任务 | 主要路径 |
|----|------|----------|
| K2.1 | CR3 切换与进程销毁顺序 | `src/ke/scheduler.zig` |
| K2.2 | 调度模型文档与可选 32 级优先级 | [SCHEDULER_API.md](SCHEDULER_API.md) |
| K2.3 | HPET/单调时钟接计时 | [TimerPrecisionRoadmap.md](TimerPrecisionRoadmap.md), `hal/x86_64/hpet.zig` |
| K2.4 | AP INIT + **SIPI×2** + 低 1MiB 实模式跳板（`lapic_smp` 0x8000）；长模式 AP + 每核调度。**进展**：`ensureLocalApicSoftwareEnabled`、`broadcastFixedIpiExcludingSelf`；**IDT 向量 254** = TLB flush IPI 桩；**`-Dlapic_periodic_tick`** 可选 LAPIC LVT 周期 tick（mask PIC IRQ0）；`apKernelEntry` 计数器 | `ap_entry.zig`, `smp_boot.zig`, `lapic_smp.zig`, `madt.zig`, `lapic_timer_tick.zig`, `interrupt_x86.zig`, `idt.zig` |
| K2.5 | TLB IPI 或可证 BSP 策略。**进展**：`requestGlobalFlushStub` 在 **`-Dsmp_tlb_ipi=true`** 且多 CPU 时广播向量 **254**（AP 须已加载 IDT；默认关闭） | `tlb_broadcast.zig` |
| K2.6 | 每 CPU 就绪队列与 `home_cpu` | `percpu_sched.zig` |
| K2.7 | IRQL：`APC_LEVEL` / `DISPATCH_LEVEL` / `DEVICE_IRQL_LOW`；**每 CPU 槽** `MAX_IRQL_CPUS=8`（运行期默认 BSP 槽 0，`setCpuSlotOverrideForTest` 供单测） | `ke/irql.zig`, `interrupt_x86.zig` |
| K2.8 | 通用 DPC：**每 CPU FIFO**（与 IRQL 槽一致）、`drainAtDispatchLevel`；输入 flush 仍为一类 DPC | `ke/dpc.zig`, `interrupt_x86.zig` |
| K2.9 | 内核/用户 APC 队列与交付点（syscall 返回用户前内核 APC；alertable 等待与用户 APC）。**进展**：`wait_user_apc_nt61_host` | `ke/apc.zig`, `ke/apc_object.zig`, `scheduler.zig`, `syscall.zig` |
| K2.10 | `KeWait` 子集：`KeWaitForSingleObject` / `KeWaitForMultipleObjects`（WaitAny）+ 超时 + alertable。**进展（阶段 C）**：`ObjectHeader` 等待队列；`enableScheduling` 后阻塞式等待 + `tick` 超时/APC 扫描；`NtCreateEvent`/`NtSetEvent` 手动·自动复位；WaitAll 仍 `STATUS_NOT_IMPLEMENTED` | `ob/object.zig`, `ke/wait.zig`, `ke/scheduler.zig`, `libs/ntdll.zig` |

## 阶段 D — Win32 消息泵与 DWM 消息对接（与 K 并行跟踪）

**详尽分解表（D0–D5）**：[PHASE_D_WIN32_MSG_PUMP_DWM.md](PHASE_D_WIN32_MSG_PUMP_DWM.md)（消息队列、`NtUserGetMessage`/`PeekMessage`、csrss LPC、`WM_DWM*`、桌面 idle 与测试门禁）。

**说明**：与 [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md) 中 **Phase D — 合成器（离屏/模糊）** 编号不同；合成器纵深仍跟该文 D1–D5 与 `dwm_compositor.zig`。

| 汇总块 | 内容 | 主路径 |
|--------|------|--------|
| D0 | 完成定义、差距表、MVT 登记 | 矩阵 §4–§5、`msg_pm_semantics.zig` |
| D1 | 消息泵 syscall 语义、`PM_*`、`WM_QUIT`。**进展**：`NtUserPeekMessage` 空队列 `STATUS_NO_MORE_ENTRIES`；`PostQuitMessage` → 线程队列；`msgPumpThreadsBlockedApprox` + 桌面循环加 poll | `user32.zig`、`syscall.zig`、`main.zig` |
| D2 | LPC `get_message` tid、`post_message`、DWM listener v1 | `subsystem.zig`、`csr_lpc_policy.zig`、`csr_dwm_listeners.zig` |
| D3 | `broadcastDwm*`、注册表同步、缩略图消息 | `dwm.zig`、`user32`、`dwm_config_registry_sync.zig` |
| D4–D5 | 桌面唤醒、主机/QEMU 测、矩阵更新 | `display.zig`、`tests/nt61/*`、`MVT_NT61.md` |

## Phase K3 — HAL：ACPI、PCIe、中断

| ID | 任务 | 主要路径 |
|----|------|----------|
| K3.1 | ACPI 表遍历与错误路径 | `acpi_pci_early.zig`, `multiboot2_parse.zig` |
| K3.2 | ECAM 枚举扩展 | `ecam_layout.zig` |
| K3.3 | IOAPIC 与 IRQ 路由。**进展**：MADT type1 记录首 IOAPIC MMIO（`madt.ioapic_mmio_phys`）；`ioapic_route.zig` 诊断里程碑；重定向表与 MSI 仍待 | `hal/x86_64/madt.zig`, `hal/x86_64/ioapic_route.zig` |
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
| K6.4 | LPC 与 csrss 契约；**ALPC 占位** `lpc/alpc_min.zig`；**csrss 骨架** `servers/csrss_skeleton.zig` | `lpc/port.zig`, [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) |

## Phase K7 — SSDT 与 Native 内核语义

**阶段 E（Native 深度补全）**：验收边界与任务表见 [PHASE_E_NATIVE_API.md](PHASE_E_NATIVE_API.md)（与 [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md) 中 Shell **Phase E** 非同里程碑）。

| ID | 任务 | 主要路径 |
|----|------|----------|
| K7.1 | SSDT 版本与 ntdll/syscall 双端；**扩展子集**（同步/进程/ALPC 等）+ `STATUS_NOT_IMPLEMENTED` 桩；真源路径 `sdk/nt61_syscall_numbers_x64.zig` | `ssdt_nt61.zig`, `syscall.zig`, `tests/nt61/syscall_numbers_lock_nt61_host.zig`, [SSDT_Roadmap.md](SSDT_Roadmap.md), [PHASE_E_NATIVE_API.md](PHASE_E_NATIVE_API.md) |
| K7.2 | 虚拟内存与系统信息类对齐 | `syscall.zig`, [NT61_VirtualMemory_ABI_Notes.md](NT61_VirtualMemory_ABI_Notes.md) |
| K7.3 | 注册表内存树与 hive 分阶段 | 路线图 |
| K7.4 | x64 SEH：`.pdata` / `RUNTIME_FUNCTION` 表驱动展开子集 | `loader/seh_pdata_min.zig`, PE 规范 |

## Phase K8 — 文件系统内核层

| ID | 任务 | 主要路径 |
|----|------|----------|
| K8.1 | NTFS/FAT 边界与错误码 | `src/fs/` |
| K8.2 | VFS–IRP 桥接与共享访问标志 | `vfs.zig` |

### K1 内存：明确延后（相对 NT 6.1 全语义）

下列项在月报/矩阵中应标为**未声称完成**，避免与商业内核等价表述混淆：

- 节区 **`PAGE_WRITECOPY` / `SEC_*` 全语义**：**文件后备**真 COW 仍为 `STATUS_NOT_IMPLEMENTED`；**匿名** WRITECOPY 已按私有 RW + fork CoW 近似。
- **每映射一次的全局 PFN 引用计数**：当前以 `shareCount`/CoW 路径为主，未在每条 `mapPage`/`unmap` 上维护与 Windows 一致的统一 refcnt；路线图见 [PFN_REFCOUNT_ROADMAP.md](PFN_REFCOUNT_ROADMAP.md)。
- **页文件、Standby/Modified 链表、真换出**：未实现；伙伴/Active PFN 与惰性 section 不替代页文件子系统。

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

## 与 NT 6.1 的 IRQL / DPC / syscall 出口差距（可跟踪清单）

下列项**不要求**单次迭代做完，但须在矩阵/本段保持可见，避免与商业内核语义混淆：

| 差距 | 说明 | 主路径 |
|------|------|--------|
| **完整 IRQL 抢占模型** | 当前为 `PASSIVE` / `APC` / `DISPATCH` / 设备 IRQ 子集；无完整 DIRQL 设备栈与 `KeRaiseIrqlToDpcLevel` 全语义 | `ke/irql.zig`, `interrupt_x86.zig` |
| **DPC 与 syscall 返回** | DPC 在 IRQ 尾声 `drainAtDispatchLevel` 排空；与 NT 在 **DISPATCH_LEVEL** 下完成 I/O 完成例程的时序仍简化 | `ke/dpc.zig`, `syscall.zig` `dispatch` |
| **APC 交付点** | 内核 APC 在 syscall 返回用户前交付；用户 APC / alertable 全语义仍部分 | `ke/apc.zig`, `ke/wait.zig` |
| **时钟与 tick 源** | PIT / 可选 LAPIC 周期 tick；HPET 单调时钟与 IRQ0 迁移见 [TimerPrecisionRoadmap.md](TimerPrecisionRoadmap.md) | `hal/x86_64/hpet.zig`, `scheduler.zig` |

## 维护

更新本清单时同步 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §7 链接与根 README 若涉及对外完成度表述。

**近期 ABI 落地**（与 [NT61_FULL_API_BACKLOG.md](NT61_FULL_API_BACKLOG.md)「实现检查点」一致）：`KUSER_SHARED_DATA` 进程映射、`TEB` x64 `LastErrorValue` 偏移断言、`kernelbase` 分层、合成 `ntdll` 基址调整 — 见 `src/mm/kuser_shared.zig`、`src/sdk/teb_nt61_x64.zig`、`src/libs/kernelbase.zig`、`tests/nt61_abi_layout_host`。
