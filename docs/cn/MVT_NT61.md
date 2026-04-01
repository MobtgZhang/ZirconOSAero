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
| IPv4 固定首部解析 | 同上 → minimal_net | [src/drivers/net/minimal_stack.zig](../../src/drivers/net/minimal_stack.zig) |
| MDL 子集（PFN 槽、恒等映射填 PFN） | 同上 → mdl_host | [src/mm/mdl.zig](../../src/mm/mdl.zig) |
| PCI 类码 / VirtIO → 驱动绑定占位 | 同上 → pci_driver_bind_host | [src/drivers/bus/pci_driver_bind.zig](../../src/drivers/bus/pci_driver_bind.zig) |
| VFS `FileAccessMode` 数值 | 同上 → fs_vfs_constants_host | [tests/fs_vfs_constants_host.zig](../../tests/fs_vfs_constants_host.zig)（与 [src/fs/vfs.zig](../../src/fs/vfs.zig) 同步） |
| 调度器策略公式（主机） | 同上 → scheduler_policy_host | [tests/scheduler_policy_host.zig](../../tests/scheduler_policy_host.zig) |
| 合规短语扫描 | `bash scripts/verify-compliance.sh` | [scripts/verify-compliance.sh](../../scripts/verify-compliance.sh)；CI |

## CI / 烟测（QEMU 或构建产物）

| 能力域 | 步骤 | 说明 |
|--------|------|------|
| 构建与 ELF | `.github/workflows/ci.yml`；本地 `zig build install` | ReleaseSafe 与横幅校验见 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) |
| ZBM / 无头启动 | `bash scripts/ci-qemu-smoke.sh` | MBR 盘、串口可选断言 |
| 节区 / 映射（用户态 API） | 运行依赖 `ntdll` 内 `NtCreateSection` / `NtMapViewOfSection` 的用例（随子系统扩展） | 内核实现见 [src/mm/section.zig](../../src/mm/section.zig)；x64 syscall 见 [src/arch/x86_64/syscall.zig](../../src/arch/x86_64/syscall.zig) |

## 维护约定

- 契约矩阵中标记为「部分」的项，须在 PR 中说明 **本表或 CI 中对应的验证** 是否已更新。
- 禁止仅改文档勾选「完成」而不增加可运行验证。
