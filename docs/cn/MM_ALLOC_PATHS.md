# 内核堆与池：分配路径全景（阶段 A）

本文档与 [src/mm/ex_pool.zig](../../src/mm/ex_pool.zig) 文件头注释同源，描述 **clean-room** 实现中的调用链与 IRQL 约束（行为对齐 WDK 公开名称，非任何私有实现复刻）。

## 入口

| API | 模块 | 池类型 | IRQL |
|-----|------|--------|------|
| `ExAllocatePoolWithTag` / `ExFreePoolWithTag` | `ex_pool.zig` → `pool.zig` | NonPaged | ≤ DISPATCH_LEVEL |
| `ExAllocatePoolWithTagType(.paged)` | 同上 | Paged | ≤ APC_LEVEL（`ke/irql` 守卫） |

## 向下分解

1. **档位（≤512B，6 档）**：`pool.zig` 优先从 **per-CPU lookaside**（`lookaside.zig`）弹出；失败则 **全局档位空闲链**；再失败则 **切新 zone 页**（`pool_zone.zig`）。
2. **超过最大档位**：`heap.zig` 通用堆（bump 快路径 + 地址有序空闲链表合并）。
3. **PagedPool 软上限**：`pool.setPagedPoolSoftLimitForTest` / `paged_pool_soft_limit_bytes`；超出时分配失败并 `notePagedPoolTrimPlaceholder`（真换出见路线图）。
4. **可增长堆**：`heap_boot.zig` 将 `heap` 接到 `vm.mapPageAlloc`（内核启动后）。

## 参考

- Microsoft Learn / WDK：`ExAllocatePoolWithTag`、Pool Types、lookaside 概念描述。
- 仓库：[MM_HEAP_POOL_SLAB.md](MM_HEAP_POOL_SLAB.md)、[MM_Section_Roadmap.md](MM_Section_Roadmap.md)、[VM_ISOLATION.md](VM_ISOLATION.md)。
