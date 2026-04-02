# NT 6.1 内核与用户态：实现状态与验证入口

本页在 **诚实状态**（与契约矩阵、内核待办一致的叙事）下，汇总 **内存与 HAL**、**进程与 syscall**、**文件系统与 PE/Win32** 的**当前焦点**与**如何验证**。细则仍以 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)、[NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) 为准。

## 如何跑自动化验证

```bash
zig build test                    # 主机侧单元测试（堆、池、SSDT、IRP、VFS 常量等）
bash scripts/ci-qemu-smoke.sh     # x86_64 ZBM MBR 串口烟测（需本地 QEMU + 构建产物）
python3 tests/run_all.py          # Python 套件（含启动组合、Multiboot2 头等）
```

GitHub Actions：`.github/workflows/ci.yml`（多架构 `zig build kernel`、ZBM UEFI 对象、`mkiso-uefi-zbm.sh`）。

## D1–D2：内存管理、中断与 HAL

| 方向 | 现状（摘要） | 跟踪文档 / 代码 |
|------|----------------|-----------------|
| 物理帧 / mmap | Multiboot2（ZBM 递交）驱动 `frame.zig`；伙伴连续页等见契约矩阵 | `src/mm/frame.zig`, `phys_buddy.zig` |
| 池与堆 | Bump + 回收 + `mm/pool` 档位；slab/伙伴演进 | [MM_HEAP_POOL_SLAB.md](MM_HEAP_POOL_SLAB.md) |
| 分页 / 隔离 | 四级表、恒等映射；每进程 CR3 与缓解见矩阵 | `src/arch/*/paging*`, `mitigations.zig` |
| 中断 / 定时器 | x86_64：PIC+PIT 主路径；IOAPIC/HPET/SMP 见 K3/K2 | [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) K2–K3, `src/hal/` |
| 其他架构 | aarch64 / riscv64 / loongarch64：向量、定时器、设备树或固件 handoff 各异 | 各 `src/arch/<arch>/`, [Boot.md](Boot.md) |

**待办锚点**：NT61_KERNEL_TODO **K1、K2、K3**。

## D3–D4：进程、调度、Nt 风格 syscall

| 方向 | 现状（摘要） | 跟踪文档 / 代码 |
|------|----------------|-----------------|
| 调度 | 多档就绪队列；非完整 NT 32 级 | [SCHEDULER_API.md](SCHEDULER_API.md), `src/ke/scheduler.zig` |
| 进程 / 线程 | Process Server、对象路径部分可用 | `src/ps/`, 契约矩阵 §0 |
| Syscall | x86_64：`syscall` + SSDT 子集；用户缓冲 probe | [SyscallABI.md](SyscallABI.md), `ssdt_nt61.zig` |
| ntdll 对齐 | 服务号与桩函数持续与 SSDT 对齐 | `src/libs/ntdll/`, K7 |

**待办锚点**：NT61_KERNEL_TODO **K2、K7**。

## D5–D7：FAT32、VFS、PE、最小 Win32

| 方向 | 现状（摘要） | 跟踪文档 / 代码 |
|------|----------------|-----------------|
| VFS / FAT32 | 挂载与主路径；与 Windows 格式化互操作非目标 | `src/fs/` |
| NTFS | **子集**（MFT 基本路径）；完整特性见长期路线 | README 功能矩阵、契约矩阵 |
| PE32+ | 头、导入、重定位、PEB/TEB **子集** | `src/loader/` |
| kernel32 / user32 | 子集；Aero 与 DWM 为部分实现 | 契约矩阵、DesktopManagerSpec |

**原则**：**先夯实 FAT32 + 静态 PE**，再扩展 NTFS 只读/子集；**WOW64 / 完整 Aero** 为长期目标，见 [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md)。

## mips64el

试验架构，**不**与 x86_64 / aarch64 / riscv64 / loongarch64 同级承诺；见 [TIER2_ARCHITECTURES.md](TIER2_ARCHITECTURES.md)、[Boot.md](Boot.md)。
