# NT 6.1 最小可验证测试（MVT）索引

本页列出与 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)、根目录 [README.md](../../README.md) 特性矩阵交叉引用的 **可复现验证** 步骤。状态标签含义见契约矩阵文首「状态标签定义」。

**PR 合并前人类勾选**：[NT61_PR_GATES.md](NT61_PR_GATES.md)（K0：矩阵、本表、syscall 注释、合规扫描）。

**内核里程碑清单**（何项应增测/更新本表）：见 [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) Phase K0；新增内核能力须在 PR 中说明是否已扩展下表或 `tests/`。

## 主机单元测试（无需 QEMU）

| 能力域 | 命令 | 覆盖模块 |
|--------|------|----------|
| 内核堆 | `zig build test` → heap | [src/mm/heap.zig](../../src/mm/heap.zig) |
| 池分配器 | 同上 → pool | [src/mm/pool.zig](../../src/mm/pool.zig) |
| 伙伴系统（逻辑块） | 同上 → buddy | [src/mm/buddy.zig](../../src/mm/buddy.zig) |
| Slab | 同上 → slab | [src/mm/slab.zig](../../src/mm/slab.zig) |
| `PAGE_*` → x86_64 PTE 位（与 `vm.zig` `ntProtectToPteFlags` 同步） | 同上 → **vm_nt_protect_pte_host** | [tests/vm_nt_protect_pte_host.zig](../../tests/vm_nt_protect_pte_host.zig) |
| TEB / KUSER x64 契约（偏移与 VA） | 同上 → **nt61_abi_layout_host** | [tests/nt61_abi_layout_host.zig](../../tests/nt61_abi_layout_host.zig)、[src/sdk/teb_nt61_x64.zig](../../src/sdk/teb_nt61_x64.zig)、[src/sdk/kuser_shared_nt61.zig](../../src/sdk/kuser_shared_nt61.zig) |
| SSDT 公开索引 | 同上 → ssdt | [src/arch/x86_64/ssdt_nt61.zig](../../src/arch/x86_64/ssdt_nt61.zig) |
| 用户态 `Ssdt` 与内核 `ssdt_nt61` 子集一致 | 同上 → ssdt_stub_parity | [tests/ssdt_stub_parity.zig](../../tests/ssdt_stub_parity.zig)、[src/sdk/ntdll_syscall_win64.zig](../../src/sdk/ntdll_syscall_win64.zig) |
| x64 与 x86（Win7 SP1 公开表）服务号不同命名空间 | 同上 → ssdt_x64_x86_namespace | [tests/ssdt_x64_x86_namespace.zig](../../tests/ssdt_x64_x86_namespace.zig) |
| WOW64 x86 服务号子集 | 同上 → wow64_ssdt_x86 | [src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig](../../src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig) |
| 安全令牌 / DAC | 同上 → se_token | [tests/se_token.zig](../../tests/se_token.zig) |
| SMP 原子占位 | 同上 → smp_atomic_host | [tests/smp_atomic_host.zig](../../tests/smp_atomic_host.zig) |
| WOW64 类型 | 同上 → wow64_types | [src/subsystems/win32/wow64/types.zig](../../src/subsystems/win32/wow64/types.zig) |
| 对象句柄表 / 路径规范化 | 同上 → object | [src/zircon_host_ob_test.zig](../../src/zircon_host_ob_test.zig)（导入 `ob/object.zig`） |
| IRP 完成例程与设备栈链镜像 | 同上 → io_irp_host | [tests/io_irp_host.zig](../../tests/io_irp_host.zig)（与 [src/io/io.zig](../../src/io/io.zig) 契约对齐） |
| PCIe ECAM 偏移 | 同上 → ecam_layout | [src/hal/x86_64/ecam_layout.zig](../../src/hal/x86_64/ecam_layout.zig) |
| HPET GCAP_ID 解码 | 同上 → hpet_id | [src/hal/x86_64/hpet_id.zig](../../src/hal/x86_64/hpet_id.zig) |
| LPC `PortKind` ABI | 同上 → lpc_portkind_host | [tests/lpc_portkind_host.zig](../../tests/lpc_portkind_host.zig) |
| IPv4 固定首部 + ARP 首部解析 | 同上 → minimal_net | [src/drivers/net/minimal_stack.zig](../../src/drivers/net/minimal_stack.zig) |
| MDL 子集（PFN 槽、恒等映射填 PFN） | 同上 → mdl_host | [src/mm/mdl.zig](../../src/mm/mdl.zig) |
| PCI 类码 / VirtIO → 驱动绑定占位 | 同上 → pci_driver_bind_host | [src/drivers/bus/pci_driver_bind.zig](../../src/drivers/bus/pci_driver_bind.zig) |
| VFS `FileAccessMode` 数值 | 同上 → fs_vfs_constants_host | [tests/fs_vfs_constants_host.zig](../../tests/fs_vfs_constants_host.zig)（与 [src/fs/vfs.zig](../../src/fs/vfs.zig) 同步） |
| 常见 `NTSTATUS` 与文件打开映射（P6-1 锚点） | 同上 → fs_status_nt_map_host | [tests/fs_status_nt_map_host.zig](../../tests/fs_status_nt_map_host.zig) |
| FULL_API_BACKLOG §1–§10 分节 CI 锚点 | 同上 → nt61_full_api_backlog_anchors_host | [tests/nt61_full_api_backlog_anchors_host.zig](../../tests/nt61_full_api_backlog_anchors_host.zig) |
| 调度器策略公式（主机） | 同上 → scheduler_policy_host | [tests/scheduler_policy_host.zig](../../tests/scheduler_policy_host.zig) |
| 互斥继承深度模型（主机） | 同上 → mutex_inherit_depth_host | [tests/mutex_inherit_depth_host.zig](../../tests/mutex_inherit_depth_host.zig) |
| Phase F 调度差额（文档化占位） | 同上 → nt61_phase_f_scheduler_gap | [tests/nt61_phase_f_scheduler_gap.zig](../../tests/nt61_phase_f_scheduler_gap.zig) |
| GpuDevice / ramfb 占位 | 同上 → gpu_device_host | [src/drivers/video/gpu_device.zig](../../src/drivers/video/gpu_device.zig) |
| Win32k 窗口骨架 | 同上 → win32k_host | [src/subsystems/win32k/mod.zig](../../src/subsystems/win32k/mod.zig) |
| Aero 标志映射（内核 ↔ 用户态 `SurfaceFlags`） | 同上 → **aero_flag_mapping_host** | [src/config/aero_flag_mapping.zig](../../src/config/aero_flag_mapping.zig) |
| COLORREF ↔ 内核 BGR（与 Aero `theme.rgb` 字节序对照） | 同上 → **color_nt61_host** | [color_nt61.zig](../../src/config/color_nt61.zig) |
| DWM 消息常量 + `WM_DWMSENDICONICTHUMBNAIL` lParam 烟测 | 同上 → **dwm_messages_nt61_host**、**dwm_nt61_integration_host** | [tests/nt61/dwm_messages_nt61.zig](../../tests/nt61/dwm_messages_nt61.zig)、[tests/nt61/dwm_nt61_integration_host.zig](../../tests/nt61/dwm_nt61_integration_host.zig) |
| DWM 公开契约常量 / 结构布局（`dwm_nt61_api_contract`） | 同上 → **dwm_nt61_api_contract_host** | [src/config/dwm_nt61_api_contract.zig](../../src/config/dwm_nt61_api_contract.zig) |
| LPC `get_message` 线程 id 策略（禁止 `tid==0`）+ `post_message` 载荷长度 | 同上 → **csr_lpc_policy_host**、**nt61_dual_track_host** | [csr_lpc_policy.zig](../../src/subsystems/win32/csr_lpc_policy.zig)、[tests/nt61/nt61_dual_track_host.zig](../../tests/nt61/nt61_dual_track_host.zig) |
| 合成 Z 序两趟模型（普通层→顶层） + 跨 band `SetWindowPos` 对齐 | 同上 → **dwm_zorder_nt61_host** | [tests/nt61/dwm_zorder_nt61_host.zig](../../tests/nt61/dwm_zorder_nt61_host.zig) |
| 多监视器 DPI 公式（与 framebuffer 一致） | 同上 → **multimon_dpi_nt61_host** | [tests/nt61/multimon_dpi_nt61_host.zig](../../tests/nt61/multimon_dpi_nt61_host.zig) |
| Aero Peek / Show Desktop 条命中 | 同上 → **taskbar_peek_hit_nt61_host** | [tests/nt61/taskbar_peek_hit_nt61_host.zig](../../tests/nt61/taskbar_peek_hit_nt61_host.zig) |
| 内核路径审计提醒（手动矩阵同步） | 同上 → **kernel_stub_audit_anchor_host** | [tests/nt61/kernel_stub_audit_anchor_host.zig](../../tests/nt61/kernel_stub_audit_anchor_host.zig) |
| ZOSH1 引导覆盖字节布局（与 `registry.mergeFromZosh1Bytes` 同步） | 同上 → **registry_zosh1_host** | [tests/nt61/registry_zosh1_host.zig](../../tests/nt61/registry_zosh1_host.zig) |
| `PeekMessage` `PM_REMOVE` / `PM_NOYIELD` 分支表（与 Learn） | 同上 → **msg_pm_semantics_host** | [msg_pm_semantics.zig](../../src/subsystems/win32/msg_pm_semantics.zig) |
| Win32k：PM/LPC 偏移/GDI ROP/Flip3D cap 锚点 | 同上 → **win32k_api_semantics_host** | [tests/nt61/win32k_api_semantics_host.zig](../../tests/nt61/win32k_api_semantics_host.zig) |
| GDI ROP 实现子集（BitBlt/StretchBlt/PatBlt） | 同上 → **gdi_rop_contract_host** | [gdi_rop_contract.zig](../../src/subsystems/win32/gdi_rop_contract.zig) |
| USB HID Boot 鼠标报告解析 | 同上 → **hid_boot_report_host** | [hid_boot_report.zig](../../src/drivers/usb/hid_boot_report.zig) |
| 合规短语扫描 | `bash scripts/verify-compliance.sh` | [scripts/verify-compliance.sh](../../scripts/verify-compliance.sh)；CI |
| 节区对象头 / 池容量 | `zig build test`（`object` 等步导入 `section.zig` 时运行其 `test`） | [src/mm/section.zig](../../src/mm/section.zig) |
| syscall 扩展：读/写文件、LPC 应答、重复句柄 | QEMU/内核烟测 + 代码审查 | [src/arch/x86_64/syscall_nt_extras.zig](../../src/arch/x86_64/syscall_nt_extras.zig)、[syscall_abi.zig](../../src/arch/x86_64/syscall_abi.zig) |
| VirtIO-Blk PCI 占位 + `B:\` 探测读 | 启动枚举日志；QEMU 含 `virtio-blk-pci` 时挂载 `B:\PROBE.TXT` | [virtio_blk_pci.zig](../../src/drivers/storage/virtio_blk_pci.zig)、[virtio_blk_scratch_fs.zig](../../src/drivers/storage/virtio_blk_scratch_fs.zig)、[acpi_pci_early.zig](../../src/hal/x86_64/acpi_pci_early.zig) |
| `seAccessCheckMask`（最小访问掩码门闸） | 主机逻辑见 `se_token` 测试镜像 | [src/se/token.zig](../../src/se/token.zig)、[tests/se_token.zig](../../tests/se_token.zig) |
| `seAccessActiveDesktopForWin32k`（活动桌面 / TCB 例外） | 同上 → **se_token**（主机镜像 + **se/token** 内 `test`） | [tests/se_token.zig](../../tests/se_token.zig)、[src/se/token.zig](../../src/se/token.zig) |

## CI / 烟测（QEMU 或构建产物）

| 能力域 | 步骤 | 说明 |
|--------|------|------|
| 构建与 ELF | `.github/workflows/ci.yml`；本地 `zig build install` | ReleaseSafe 与横幅校验见 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) |
| ZBM / 无头启动 | `bash scripts/ci-qemu-smoke.sh` | MBR 盘、串口可选断言；`CI_SMOKE_DESKTOP=aero` 可走完整壳层（见脚本注释） |
| CPU 合成性能基线（人工） | `bash scripts/qemu_desktop_perf_baseline.sh` | 记录 `getDesktopComposeTelemetry` / 串口 blur 统计步骤；非硬性 60fps |
| aarch64 桌面相关编译闸门 | `.github/workflows/ci.yml`：`zig build kernel -Darch=aarch64 -Ddesktop-full=true` | 与 x86_64 **desktop-full** 选项一致 |
| 分辨率与串口日志 | 改 `build.conf` 的 `RESOLUTION` → `make sync-resolution` → `make build` → QEMU/串口 | 核对 `Config: display=`、`FB tag`、`Framebuffer Driver` 宽高与 `RESOLUTION` 一致（见 [AeroDesktopRuntime.md](AeroDesktopRuntime.md) §4.2.2） |
| VirtIO-GPU 控制队列 + 2D 传输烟测 | 见 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md)「VirtIO-GPU（可选）」完整 QEMU 命令行。成功：`VirtIO-GPU: GET_DISPLAY_INFO + RESOURCE_CREATE_2D + TRANSFER_* scratch loop ok`，并可能出现 `display ↔ scratch TRANSFER round-trip ok`。无设备或 2D 失败：不出现上述 info（或出现 framebuffer round-trip `warn`），`compositorOffloadAvailable()` 为 false | [virtio_gpu_pci.zig](../../src/drivers/video/virtio_gpu_pci.zig)、[display.zig](../../src/drivers/video/display.zig) |
| PS/2 + VirtIO 并存 | `zig build -Dps2_mouse_with_virtio=true`（真机单指针源）；默认 QEMU 仍避免双源 | [arch/x86_64/mod.zig](../../src/arch/x86_64/mod.zig) `handleMouseIrq`；[PointerPolicy_NT61.md](PointerPolicy_NT61.md) §4 |
| USB HID 鼠标里程碑（问题六 / 可执行拆分） | **M1**：`-Dusb_xhci=true` 枚举 + xHCI 桩；串口检索 **`USB: xhci_mvt`**（与 **`USB: xHCI active`** 同次初始化）；**M2**：**hid_boot_report_host** + `hid.zig`；**M3**：`input_hub.zig` 轮询顺序 + PointerPolicy §4 | 契约矩阵 §4.1「USB HID 鼠标」行 |
| Flip3D shell 过滤与 Z 序模型 | 主机 **dwm_zorder_nt61_host** | [tests/nt61/dwm_zorder_nt61_host.zig](../../tests/nt61/dwm_zorder_nt61_host.zig) |
| （可选 nightly）Flip3D 打开 | 串口人工检索 `flip3d_overlay` / 热键切换日志 | 非 CI 硬性 |
| DWM 盒式模糊预算成本（`w×h×passes`） | `zig build test` → **dwm_blur_budget_host** | [dwm_blur_budget.zig](../../src/config/dwm_blur_budget.zig)、[dwm.zig](../../src/drivers/video/dwm.zig) |
| Aero 每帧模糊统计 | `zig build -Ddwm_blur_stats=true`；串口检索关键字 **`dwm blur frame:`**（`box_blur_calls` / `budget_denials` / `tint_only_calls`）。相对基线表见 [AeroDesktopRuntime.md](AeroDesktopRuntime.md) §3.0 | [display.zig](../../src/drivers/video/display.zig) `renderDesktopFrameEx` 末尾、`dwm.flushBlurFrameStatsDebug` |
| 节区 / 映射（用户态 API） | 运行依赖 `ntdll` 内 `NtCreateSection` / `NtMapViewOfSection` 的用例（随子系统扩展） | 内核实现见 [src/mm/section.zig](../../src/mm/section.zig)；x64 syscall 见 [src/arch/x86_64/syscall.zig](../../src/arch/x86_64/syscall.zig) |

## 维护约定

- 契约矩阵中标记为「部分」的项，须在 PR 中说明 **本表或 CI 中对应的验证** 是否已更新。
- 禁止仅改文档勾选「完成」而不增加可运行验证。
