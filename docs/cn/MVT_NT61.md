# NT 6.1 最小可验证测试（MVT）索引

本页列出与 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)、根目录 [README.md](../../README.md) 特性矩阵交叉引用的 **可复现验证** 步骤。状态标签含义见契约矩阵文首「状态标签定义」。

## 主机单元测试（无需 QEMU）

| 能力域 | 命令 | 覆盖模块 |
|--------|------|----------|
| 内核堆 | `zig build test` → heap | [src/mm/heap.zig](../../src/mm/heap.zig) |
| 池分配器 | 同上 → pool | [src/mm/pool.zig](../../src/mm/pool.zig) |
| 伙伴系统（逻辑块） | 同上 → buddy | [src/mm/buddy.zig](../../src/mm/buddy.zig) |
| Slab | 同上 → slab | [src/mm/slab.zig](../../src/mm/slab.zig) |
| SSDT 公开索引 | 同上 → ssdt | [src/arch/x86_64/ssdt_nt61.zig](../../src/arch/x86_64/ssdt_nt61.zig) |
| 安全令牌 / DAC | 同上 → se_token | [tests/se_token.zig](../../tests/se_token.zig) |
| SMP 原子占位 | 同上 → smp_atomic_host | [tests/smp_atomic_host.zig](../../tests/smp_atomic_host.zig) |
| WOW64 类型 | 同上 → wow64_types | [src/subsystems/win32/wow64/types.zig](../../src/subsystems/win32/wow64/types.zig) |
| 对象句柄表 | 同上 → object | [src/zircon_host_ob_test.zig](../../src/zircon_host_ob_test.zig)（导入 `ob/object.zig`） |

## CI / 烟测（QEMU 或构建产物）

| 能力域 | 步骤 | 说明 |
|--------|------|------|
| 构建与 ELF | `.github/workflows/ci.yml`；本地 `zig build install` | ReleaseSafe 与横幅校验见 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) |
| ZBM / 无头启动 | `bash scripts/ci-qemu-smoke.sh` | MBR 盘、串口可选断言 |
| 节区 / 映射（用户态 API） | 运行依赖 `ntdll` 内 `NtCreateSection` / `NtMapViewOfSection` 的用例（随子系统扩展） | 内核实现见 [src/mm/section.zig](../../src/mm/section.zig)；x64 syscall 见 [src/arch/x86_64/syscall.zig](../../src/arch/x86_64/syscall.zig) |

## 维护约定

- 契约矩阵中标记为「部分」的项，须在 PR 中说明 **本表或 CI 中对应的验证** 是否已更新。
- 禁止仅改文档勾选「完成」而不增加可运行验证。
