# NT 6.1 最小可验证测试（MVT）索引

本页维护 **可复现验证** 步骤及与 `tests/`、`zig build test` 的映射。**子系统承诺与状态列**以 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 与根 [README.md](../../README.md) 为准；**状态标签定义**见 [../DOCS_INDEX.md](../DOCS_INDEX.md) §STATUS_LEGEND。**文档职责与状态标签**：[../DOCS_INDEX.md](../DOCS_INDEX.md) §STATUS_LEGEND 与 §维护约定。

**PR 门禁**：[NT61_PR_GATES.md](NT61_PR_GATES.md)。**何时扩展本表**： [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) Phase K0。

## 阶段 A/B/C 收口 + E 门禁（摘要）

- **A/B/C**：以本表 **主机 `zig build test` 全绿** 为准；阶段 C DWM/LPC 细项见 [阶段 C 计划](.cursor/plans/阶段c_dwm合成待办_44633382.plan.md) 与 **dwm_*** / **lpc_*** 主机测；QEMU 烟测见下文 **CI / 烟测**。
- **阶段 E**：WOW64 `int 0x2E`、AHCI 分区偏移、`NtShutdownSystem`、USB HID Boot 键盘路径等须在 PR 中对照 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 与 [PHASE_G_WOW64.md](PHASE_G_WOW64.md)。

## 主机单元测试（无需 QEMU）

| 能力域 | 命令 | 覆盖模块 |
|--------|------|----------|
| 内核堆 | `zig build test` → heap | [src/mm/heap.zig](../../src/mm/heap.zig) |
| 池分配器 | 同上 → pool | [src/mm/pool.zig](../../src/mm/pool.zig)（含 **PagedPool 软上限**、`notePagedPoolTrimPlaceholder`） |
| 池 / 堆分配路径（IRQL、lookaside、heap 回退） | 文档审查 + `ex_pool` 注释 | [MM_ALLOC_PATHS.md](MM_ALLOC_PATHS.md)、[src/mm/ex_pool.zig](../../src/mm/ex_pool.zig) |
| 伙伴系统（逻辑块） | 同上 → buddy | [src/mm/buddy.zig](../../src/mm/buddy.zig) |
| Slab | 同上 → slab | [src/mm/slab.zig](../../src/mm/slab.zig) |
| `PAGE_*` → x86_64 PTE 位（与 `vm.zig` `ntProtectToPteFlags` 同步） | 同上 → **vm_nt_protect_pte_host** | [tests/vm_nt_protect_pte_host.zig](../../tests/vm_nt_protect_pte_host.zig) |
| TEB / KUSER x64 契约（偏移与 VA） | 同上 → **nt61_abi_layout_host** | [tests/nt61_abi_layout_host.zig](../../tests/nt61_abi_layout_host.zig)、[src/sdk/teb_nt61_x64.zig](../../src/sdk/teb_nt61_x64.zig)、[src/sdk/kuser_shared_nt61.zig](../../src/sdk/kuser_shared_nt61.zig) |
| SSDT 公开索引 | 同上 → ssdt | [src/arch/x86_64/ssdt_nt61.zig](../../src/arch/x86_64/ssdt_nt61.zig) |
| 用户态 `Ssdt` 与内核 `ssdt_nt61` 子集一致（含 `NtCreateUserProcess` **0xAA**） | 同上 → ssdt_stub_parity | [tests/ssdt_stub_parity.zig](../../tests/ssdt_stub_parity.zig)（`ZirconCreateUserProcessArgs` 32B 布局）、[src/sdk/ntdll_syscall_win64.zig](../../src/sdk/ntdll_syscall_win64.zig) |
| x64 与 x86（Win7 SP1 公开表）服务号不同命名空间 | 同上 → ssdt_x64_x86_namespace | [tests/ssdt_x64_x86_namespace.zig](../../tests/ssdt_x64_x86_namespace.zig) |
| WOW64 x86 服务号子集 | 同上 → wow64_ssdt_x86 | [src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig](../../src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig) |
| WOW64 x86→x64 语义别名映射 | 同上 → wow64_x64_semantic_alias_host | [x64_semantic_alias.zig](../../src/subsystems/win32/wow64/x64_semantic_alias.zig)、[wow64_x64_semantic_alias_host.zig](../../src/wow64_x64_semantic_alias_host.zig) |
| WOW64 路径/注册表重定向占位 | 同上 → wow64_redirect_host | [src/subsystems/win32/wow64/redirect.zig](../../src/subsystems/win32/wow64/redirect.zig) |
| 安全令牌 / DAC / `seAccessCheckMask` 镜像 | 同上 → se_token | [tests/se_token.zig](../../tests/se_token.zig)、[src/se/token.zig](../../src/se/token.zig) |
| SMP 原子占位 | 同上 → smp_atomic_host | [tests/smp_atomic_host.zig](../../tests/smp_atomic_host.zig) |
| WOW64 类型 | 同上 → wow64_types | [src/subsystems/win32/wow64/types.zig](../../src/subsystems/win32/wow64/types.zig) |
| 对象句柄表 / 路径规范化 / 单层符号链接 / **ObjectHeader 等待链 FIFO** | 同上 → object | [src/zircon_host_ob_test.zig](../../src/zircon_host_ob_test.zig)（导入 `ob/object.zig`；`build_options` 注入以编译 `arch`）；**节对象末引用 cleanup hook**；`waitListAppend` / `waitListRemove` 主机用例 |
| IRP 完成例程与设备栈链镜像 | 同上 → io_irp_host | [tests/io_irp_host.zig](../../tests/io_irp_host.zig)（与 [src/io/io.zig](../../src/io/io.zig) 契约对齐；含 `NOT_IMPLEMENTED` 栈下降镜像） |
| PCIe ECAM 偏移 | 同上 → ecam_layout | [src/hal/x86_64/ecam_layout.zig](../../src/hal/x86_64/ecam_layout.zig) |
| HPET GCAP_ID 解码 | 同上 → hpet_id | [src/hal/x86_64/hpet_id.zig](../../src/hal/x86_64/hpet_id.zig) |
| LPC `PortKind` ABI | 同上 → lpc_portkind_host | [tests/lpc_portkind_host.zig](../../tests/lpc_portkind_host.zig) |
| LPC `handshake_version`（v2 锚点） | 同上 → **lpc_handshake_version_host** | [tests/lpc_handshake_version_host.zig](../../tests/lpc_handshake_version_host.zig) |
| LPC 两 PID 队列往返（镜像 `ipc.zig`） | 同上 → **lpc_two_pid_host** | [tests/lpc_two_pid_host.zig](../../tests/lpc_two_pid_host.zig) |
| LPC `NtRequestWaitReplyPort` 坏缓冲区 NTSTATUS 锚点 | 同上 → **lpc_bad_pointer_host** | [tests/lpc_bad_pointer_host.zig](../../tests/lpc_bad_pointer_host.zig) |
| `NtQueryInformationProcess` / `ProcessCommandLineInformation`（映像名近似 UNICODE_STRING） | 同上 → 内核 **`ntdll`** `test` / 代码审查 | [src/libs/ntdll.zig](../../src/libs/ntdll.zig) |
| `NtAllocateVirtualMemory` 未支持 `MEM_*` 位 → `STATUS_NOT_IMPLEMENTED` | 同上 → 代码审查 + **ntdll** | [src/libs/ntdll.zig](../../src/libs/ntdll.zig) |
| `SystemVersionInformation` / `RTL_OSVERSIONINFOEXW` 284 字节 | 同上 → **nt61_os_version_layout_host** | [tests/nt61_os_version_layout_host.zig](../../tests/nt61_os_version_layout_host.zig)、[`os_version.zig`](../../src/config/os_version.zig) |
| `RtlVerifyVersionInfo` / `VerSetConditionMask` 语义子集 | 同上 → **rtl_verify_version_info_host** | [rtl_verify_version_info_host.zig](../../src/rtl_verify_version_info_host.zig)、[`os_version.zig`](../../src/config/os_version.zig)、[`ntdll.zig`](../../src/libs/ntdll.zig) |
| ntdll/kernel32/user32 合成导出顺序 | 同上 → **nt61_core_dll_abi_inventory_host** | [`nt61_core_dll_abi_inventory.zig`](../../src/config/nt61_core_dll_abi_inventory.zig)、[CORE_DLL_PE_EXPORT_STRATEGY.md](CORE_DLL_PE_EXPORT_STRATEGY.md) |
| PE TLS/delay/bound 策略失败码（镜像） | 同上 → **pe_loader_policy_host** | [tests/pe_loader_policy_host.zig](../../tests/pe_loader_policy_host.zig) |
| `SEC_IMAGE` + `IMAGE_SECTION_HEADER` 40 字节 | 同上 → **pe64_nt61_host** | [sdk/pe64_nt61.zig](../../sdk/pe64_nt61.zig) |
| fork 子集 dup + 只读子映射 + `tryCowWriteFault` PFN 分离 | 同上 → **fork_cow_share_nt61_host** | [src/fork_cow_share_nt61_host.zig](../../src/fork_cow_share_nt61_host.zig)（模块根在 `src/`，与 `vm.zig` 同模块） |
| **阶段3：LoongArch64 ASID / fork / VAD**（K1.4/K1.4b/K1.8）：ASID 位图分配/释放（255 次压力）、version_bump 递增验证；KPCR `PerCpu.current_asid` 访问器；fork/CoW API 存在性；VAD `partially_committed` / `upgradeReservedContaining` / `coalesceAdjacent` / `decommitSubrange` API 存在性；32MiB 块 = 2048×16KiB 页 | 同上 → **loongarch_nt61_mm_host** | [tests/host/loongarch_nt61_mm_host.zig](../../tests/host/loongarch_nt61_mm_host.zig) |
| 缺口优先级表（K1–K8 × 二进制兼容） | 文档审查 | [BINARY_COMPAT_GAP_AUDIT.md](BINARY_COMPAT_GAP_AUDIT.md) |
| IPv4 固定首部 + ARP 首部解析 | 同上 → minimal_net | [src/drivers/net/minimal_stack.zig](../../src/drivers/net/minimal_stack.zig) |
| MDL 子集（PFN 槽、恒等映射填 PFN） | 同上 → mdl_host | [src/mm/mdl.zig](../../src/mm/mdl.zig) |
| PCI 类码 / VirtIO → 驱动绑定占位 | 同上 → pci_driver_bind_host | [src/drivers/bus/pci_driver_bind.zig](../../src/drivers/bus/pci_driver_bind.zig) |
| VFS `FileAccessMode` 数值 | 同上 → fs_vfs_constants_host | [tests/fs_vfs_constants_host.zig](../../tests/fs_vfs_constants_host.zig)（与 [src/fs/vfs.zig](../../src/fs/vfs.zig) 同步） |
| **MBR / GPT 分区表解析（fixture）** | 同上 → **partition_table_host** | [partition_table.zig](../../src/drivers/storage/partition_table.zig)（模块根内 `test`） |
| 常见 `NTSTATUS` 与文件打开映射（P6-1 锚点） | 同上 → fs_status_nt_map_host | [tests/fs_status_nt_map_host.zig](../../tests/fs_status_nt_map_host.zig) |
| FULL_API_BACKLOG §1–§10 分节 CI 锚点（导入 `ssdt` 真断言） | 同上 → nt61_full_api_backlog_anchors_host | [tests/nt61_full_api_backlog_anchors_host.zig](../../tests/nt61_full_api_backlog_anchors_host.zig)；阶段 E 清单 [PHASE_E_NATIVE_API.md](PHASE_E_NATIVE_API.md) |
| 调度器策略公式（主机） | 同上 → scheduler_policy_host | [tests/scheduler_policy_host.zig](../../tests/scheduler_policy_host.zig) |
| 互斥继承深度模型（主机） | 同上 → mutex_inherit_depth_host | [tests/mutex_inherit_depth_host.zig](../../tests/mutex_inherit_depth_host.zig) |
| Phase F 调度差额（文档化占位） | 同上 → nt61_phase_f_scheduler_gap | [tests/nt61_phase_f_scheduler_gap.zig](../../tests/nt61_phase_f_scheduler_gap.zig) |
| GpuDevice / ramfb 占位 | 同上 → gpu_device_host | [src/drivers/video/core/gpu_device.zig](../../src/drivers/video/core/gpu_device.zig) |
| Win32k 窗口骨架 | 同上 → win32k_host | [src/subsystems/win32k/mod.zig](../../src/subsystems/win32k/mod.zig) |
| Aero 标志映射（内核 ↔ 用户态 `SurfaceFlags`） | 同上 → **aero_flag_mapping_host** | [src/config/aero_flag_mapping.zig](../../src/config/aero_flag_mapping.zig) |
| COLORREF ↔ 内核 BGR（与 Aero `theme.rgb` 字节序对照） | 同上 → **color_nt61_host** | [color_nt61.zig](../../src/config/color_nt61.zig) |
| DWM 消息常量 + `WM_DWMSENDICONICTHUMBNAIL` / **`WM_DWMSENDICONICLIVEPREVIEWBITMAP`** lParam 烟测 + 打包器 + `classifyVirtioRuntimePhase`（含 `submit3d_noop_ok`）+ `DWM_E_COMPOSITIONDISABLED` / `DWM_THUMBNAIL_PROPERTIES` 布局锚点 + 注册表 `Composition` 广播提示 | 同上 → **dwm_messages_nt61_host**、**dwm_nt61_integration_host** | [tests/nt61/dwm_messages_nt61.zig](../../tests/nt61/dwm_messages_nt61.zig)、[tests/nt61/dwm_nt61_integration_host.zig](../../tests/nt61/dwm_nt61_integration_host.zig) |
| 阶段 C：`COMPOSITOR_TREE_SYNC_V1` / `KERNEL_DWM_NOTIFY_V1` LPC 载荷（含 13 表面分片上限） | 同上 → **compositor_sync_nt61_host**、**dwm_nt61_integration_host**（`GetMessage` 0,0 与 DWM 常量） | [compositor_sync_nt61.zig](../../src/config/compositor_sync_nt61.zig)、[SOFTWARE_COMPOSITOR_WDDM.md](SOFTWARE_COMPOSITOR_WDDM.md) 阶段 C |
| DWM 公开契约常量 / 结构布局（`dwm_nt61_api_contract`） | 同上 → **dwm_nt61_api_contract_host** | [src/config/dwm_nt61_api_contract.zig](../../src/config/dwm_nt61_api_contract.zig)（含 `iconicSizeRequestLParam` 等主机 `test`） |
| `dwmapi` 导出名表（与 `pe.zig` 合成 DLL 顺序一致） | 同上 → **dwm_nt61_abi_inventory_host** | [dwm_nt61_abi_inventory.zig](../../src/config/dwm_nt61_abi_inventory.zig)；策略 [DWMAPI_PE_EXPORT_STRATEGY.md](DWMAPI_PE_EXPORT_STRATEGY.md) |
| WOW64 `dwmapi` PE32 布局（`DWM_BLURBEHIND32` / HWND 扩展） | 同上 → **dwmapi_wow64_host** | [dwmapi_wow64.zig](../../src/subsystems/win32/dwmapi_wow64.zig) |
| NTFS 簇大小与 hive 路线图锚点 | 同上 → **ntfs_hive_minimum_host** | [tests/nt61/ntfs_hive_minimum_host.zig](../../tests/nt61/ntfs_hive_minimum_host.zig) |
| 阶段 4：窗口站 LPC 操作码、WOW64 x86 `NtConnectPort`/`NtRequestWaitReplyPort`、NTFS `D:\` ZOSH1 路径 | 同上 → **phase4_host_anchors** | [tests/nt61/phase4_host_anchors.zig](../../tests/nt61/phase4_host_anchors.zig)；[PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](PHASE4_HARDWARE_SYSTEM_INTEGRATION.md) |
| LPC `get_message` 线程 id 策略（禁止 `tid==0`）+ `post_message` 载荷长度 + **`register_dwm_listener` v1** | 同上 → **csr_lpc_policy_host**、**dwm_messages_nt61_host**、**nt61_dual_track_host** | [csr_lpc_policy.zig](../../src/subsystems/win32/csr_lpc_policy.zig)、[LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) |
| 合成 Z 序两趟模型（普通层→顶层） + 跨 band `SetWindowPos` 对齐 + `HWND_NOTOPMOST` Learn（非 topmost 不重排）叙事锚点 | 同上 → **dwm_zorder_nt61_host** | [tests/nt61/dwm_zorder_nt61_host.zig](../../tests/nt61/dwm_zorder_nt61_host.zig) |
| 多监视器 DPI 公式（与 framebuffer 一致） | 同上 → **multimon_dpi_nt61_host** | [tests/nt61/multimon_dpi_nt61_host.zig](../../tests/nt61/multimon_dpi_nt61_host.zig) |
| Aero Peek / Show Desktop 条命中 | 同上 → **taskbar_peek_hit_nt61_host** | [tests/nt61/taskbar_peek_hit_nt61_host.zig](../../tests/nt61/taskbar_peek_hit_nt61_host.zig) |
| 开始菜单 `needs_startmenu_repaint` 不与 `needs_full_scene` 合并升全屏（主机镜像） | 同上 → **startmenu_paint_hint_nt61_host** | [tests/nt61/startmenu_paint_hint_nt61_host.zig](../../tests/nt61/startmenu_paint_hint_nt61_host.zig) |
| 内核路径审计提醒（手动矩阵同步） | 同上 → **kernel_stub_audit_anchor_host** | [tests/nt61/kernel_stub_audit_anchor_host.zig](../../tests/nt61/kernel_stub_audit_anchor_host.zig) |
| ZOSH1 引导覆盖字节布局（与 `registry.mergeFromZosh1Bytes` 同步） | 同上 → **registry_zosh1_host** | [tests/nt61/registry_zosh1_host.zig](../../tests/nt61/registry_zosh1_host.zig) |
| `PeekMessage` `PM_REMOVE` / `PM_NOYIELD`；`NtUserPeekMessage`/`GetMessage` 与 Learn 差距表；`SetWindowPos` `SWP_*` 数值锚点 | 同上 → **msg_pm_semantics_host** | [msg_pm_semantics.zig](../../src/subsystems/win32/msg_pm_semantics.zig) |
| Win32k：PM/LPC 偏移/GDI ROP/Flip3D cap 锚点 | 同上 → **win32k_api_semantics_host** | [tests/nt61/win32k_api_semantics_host.zig](../../tests/nt61/win32k_api_semantics_host.zig) |
| GDI ROP 实现子集（BitBlt/StretchBlt/PatBlt） | 同上 → **gdi_rop_contract_host** | [gdi_rop_contract.zig](../../src/subsystems/win32/gdi_rop_contract.zig) |
| USB HID Boot 鼠标报告解析 | 同上 → **hid_boot_report_host** | [hid_boot_report.zig](../../src/drivers/usb/hid_boot_report.zig) |
| 合规短语扫描 | `bash scripts/verify-compliance.sh` | [scripts/verify-compliance.sh](../../scripts/verify-compliance.sh)；CI |
| 节区对象头 / 池容量 | `zig build test`（`object` 等步导入 `section.zig` 时运行其 `test`） | [src/mm/section.zig](../../src/mm/section.zig) |
| syscall 扩展：读/写文件、**DeviceIoControl**、LPC 应答、重复句柄 | QEMU/内核烟测 + 代码审查 | [syscall_nt_extras.zig](../../src/arch/x86_64/syscall_nt_extras.zig)（`NtDeviceIoControlFile`）、[syscall_dispatch_mm.zig](../../src/arch/x86_64/syscall_dispatch_mm.zig)（Lock/Unlock VM）、[syscall_abi.zig](../../src/arch/x86_64/syscall_abi.zig) |
| VirtIO-Blk PCI 占位 + `B:\` 探测读 | 启动枚举日志；QEMU 含 `virtio-blk-pci` 时挂载 `B:\PROBE.TXT` | [virtio_blk_pci.zig](../../src/drivers/storage/virtio_blk_pci.zig)、[virtio_blk_scratch_fs.zig](../../src/drivers/storage/virtio_blk_scratch_fs.zig)、[acpi_pci_early.zig](../../src/hal/x86_64/acpi_pci_early.zig) |
| `seAccessCheckMask`（最小访问掩码门闸） | 主机逻辑见 `se_token` 测试镜像 | [src/se/token.zig](../../src/se/token.zig)、[tests/se_token.zig](../../tests/se_token.zig) |
| `seAccessActiveDesktopForWin32k`（活动桌面 / TCB 例外） | 同上 → **se_token**（主机镜像 + **se/token** 内 `test`） | [tests/se_token.zig](../../tests/se_token.zig)、[src/se/token.zig](../../src/se/token.zig) |

## CI / 烟测（QEMU 或构建产物）

| 能力域 | 步骤 | 说明 |
|--------|------|------|
| 构建与 ELF | `.github/workflows/ci.yml`；本地 `zig build install` | ReleaseSafe 与横幅校验见 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) |
| 最小 x64 PE（仓库内，`ExitProcess`） | `zig build minimal-pe-nt61` | 输出 `zig-out/bin/zircon_nt61_minimal_pe.exe`；[`tools/minimal_pe_nt61/minimal_pe.zig`](../../tools/minimal_pe_nt61/minimal_pe.zig)；可选 QEMU 加载实验（不依赖微软闭源 DLL） |
| **阶段3：LoongArch64 SMP 烟测**（AP 启动、ASID 分配、调度器多核） | `zig build run-qemu-smp-test` | 需 QEMU + LoongArch64 固件 + ESP 镜像；SMP=2；串口检索 `LoongArch SMP: AP%u initializing`；脚本 [`scripts/qemu_loongarch64_smp_test.sh`](../../scripts/qemu_loongarch64_smp_test.sh)；构建闸门：`zig build` |
| ZBM / 无头启动 | `bash scripts/ci-qemu-smoke.sh` | MBR 盘、串口可选断言；`CI_SMOKE_DESKTOP=aero` 可走完整壳层（见脚本注释） |
| **ACPI S5 / `NtShutdownSystem`** | QEMU `-no-reboot` 或串口检索 `ACPI PM:` | [`acpi_pm.zig`](../../src/hal/x86_64/acpi_pm.zig)；须令牌 **`PRIV_SHUTDOWN`**；SSDT **0x40/0x41**（[`ssdt_nt61.zig`](../../src/arch/x86_64/ssdt_nt61.zig)）。无 PM1a 时回退 `arch.shutdown()`。 |
| **PIC 向量 0x30+（WOW64 释放 0x2E）** | 串口 tick/键盘中断仍正常 | [`pic.zig`](../../src/hal/x86_64/pic.zig)、[`lapic_timer_tick.zig`](../../src/hal/x86_64/lapic_timer_tick.zig) |
| **USB xHCI Boot 键盘** | `-device qemu-xhci` + `-device usb-kbd` | 串口 `USB: HID boot … proto=1`；[`hid.zig`](../../src/drivers/usb/hid.zig)；与 PS/2 优先级见 [`input_hub.zig`](../../src/drivers/input/input_hub.zig) |
| **EHCI（可选）** | `-device usb-ehci` | [`ehci.zig`](../../src/drivers/usb/ehci.zig) 当前桩；QH/qTD 后续项 |
| CPU 合成性能基线（人工） | `bash scripts/qemu_desktop_perf_baseline.sh` | 记录 `getDesktopComposeTelemetry` / 串口 blur 统计步骤；非硬性 60fps |
| 阶段 C 模糊预算 × 分辨率（1080p / 800×600，人工） | `bash scripts/dwm_blur_resolution_matrix.sh` 后按脚本改 `RESOLUTION` 重建 + QEMU | `-Ddwm_blur_stats=true`、`-Dmouse_debug=true`；默认阈值见 `nt61_aero_defaults` / `dwm_blur_budget`；详 [SOFTWARE_COMPOSITOR_WDDM.md](SOFTWARE_COMPOSITOR_WDDM.md) |
| 阶段 4 呈现 A/B | `zig build` 对比 `-Dforce_gop_present=true` 与默认；QEMU `-device virtio-gpu-pci` | 串口应出现 `present_backend=` / `compositor_backend=` 与 [PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](PHASE4_HARDWARE_SYSTEM_INTEGRATION.md) |
| aarch64 桌面相关编译闸门 | `.github/workflows/ci.yml`：`zig build kernel -Darch=aarch64 -Ddesktop-full=true` | 与 x86_64 **desktop-full** 选项一致 |
| 分辨率与串口日志 | 改 `build.conf` 的 `RESOLUTION` → `make sync-resolution` → `make build` → QEMU/串口 | 核对 `Config: display=`、`FB tag`、`Framebuffer Driver` 宽高与 `RESOLUTION` 一致（见 [AeroDesktopRuntime.md](AeroDesktopRuntime.md) §4.2.2） |
| x86_64 分辨率 **编译**矩阵（不改仓内单行 `RESOLUTION`） | `bash scripts/test_x86_resolution_matrix.sh`；CI：`--quick` | 与 `build.conf` 注释表同款档位；`LoongArch` 见 `scripts/test_loongarch_resolution_matrix.sh`；详 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) |
| VirtIO-GPU 控制队列 + 2D 传输烟测 | 见 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md)「VirtIO-GPU（可选）」完整 QEMU 命令行。成功：`VirtIO-GPU: GET_DISPLAY_INFO + RESOURCE_CREATE_2D + TRANSFER_* scratch loop ok`，并可能出现 `display ↔ scratch TRANSFER round-trip ok`；串口 **`Desktop display phase`** 行含 `present_backend=virtio_scanout`（scanout 成功时）或 `gop_linear`。无设备：`present_backend=gop_linear`。主机：`display_flip_journal`（含 `noteVirtioPresentFlushBatch`） | [virtio_gpu_pci.zig](../../src/drivers/video/virtio/virtio_gpu_pci.zig)、[display.zig](../../src/drivers/video/core/display.zig)、[display_backend.zig](../../src/drivers/video/core/display_backend.zig) |
| PS/2 + VirtIO 并存 | `zig build -Dps2_mouse_with_virtio=true`（真机单指针源）；默认 QEMU 仍避免双源 | [arch/x86_64/mod.zig](../../src/arch/x86_64/mod.zig) `handleMouseIrq`；[PointerPolicy_NT61.md](PointerPolicy_NT61.md) §4 |
| USB HID 鼠标里程碑（问题六 / 可执行拆分） | **M1**：`-Dusb_xhci=true` 枚举 + xHCI 桩；串口检索 **`USB: xhci_mvt`**（与 **`USB: xHCI active`** 同次初始化）；**M2**：**hid_boot_report_host** + `hid.zig`；**M3**：`input_hub.zig` 轮询顺序 + PointerPolicy §4 | 契约矩阵 §4.1「USB HID 鼠标」行 |
| Flip3D shell 过滤与 Z 序模型 | 主机 **dwm_zorder_nt61_host** | [tests/nt61/dwm_zorder_nt61_host.zig](../../tests/nt61/dwm_zorder_nt61_host.zig) |
| （可选 nightly）Flip3D：Alt+Tab 打开/轮转、`Esc` 关闭、`Desktop display phase` 含 `virgl_submit3d_noop_ok`（VirGL+QEMU） | 串口人工检索 **Flip3D (Alt+Tab)**、`CMD_SUBMIT_3D size=0 ok` | 非 CI 硬性 |
| DWM 盒式模糊预算成本（`w×h×passes`） | `zig build test` → **dwm_blur_budget_host** | [dwm_blur_budget.zig](../../src/config/dwm_blur_budget.zig)、[dwm.zig](../../src/drivers/video/core/dwm.zig) |
| Aero 每帧模糊统计 | `zig build -Ddwm_blur_stats=true`；串口检索关键字 **`dwm blur frame:`**（`box_blur_calls` / `budget_denials` / `tint_only_calls`）。相对基线表见 [AeroDesktopRuntime.md](AeroDesktopRuntime.md) §3.0 | [display.zig](../../src/drivers/video/core/display.zig) `renderDesktopFrameEx` 末尾、`dwm.flushBlurFrameStatsDebug` |
| 节区 / 映射（用户态 API） | 运行依赖 `ntdll` 内 `NtCreateSection` / `NtMapViewOfSection` 的用例（随子系统扩展） | 内核实现见 [src/mm/section.zig](../../src/mm/section.zig)；x64 syscall 见 [src/arch/x86_64/syscall.zig](../../src/arch/x86_64/syscall.zig) |

## 维护约定

- 契约矩阵中标记为「部分」的项，须在 PR 中说明 **本表或 CI 中对应的验证** 是否已更新。
- 禁止仅改文档勾选「完成」而不增加可运行验证。
- **阶段 D（Win32 消息泵与 DWM/LPC）**：每落地一项语义，须在本表增列对应 `zig build test` 步或 QEMU 烟测命令；分解清单见 [PHASE_D_WIN32_MSG_PUMP_DWM.md](PHASE_D_WIN32_MSG_PUMP_DWM.md) §D5。
