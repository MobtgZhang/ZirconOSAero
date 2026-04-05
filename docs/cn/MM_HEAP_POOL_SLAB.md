# 内核堆、池与后续 slab/伙伴（边界说明）

## 当前实现（与代码一致）

| 组件 | 路径 | 职责 |
|------|------|------|
| 通用堆 | `src/mm/heap.zig` | bump 为 arena 内优化；**空闲链表合并**为主路径；**`realloc`**（新块+拷贝+释放）；可增长 arena（`heap_boot.zig`）；大块与池 zone 优先 |
| VM 接线 | `src/mm/heap_boot.zig` | 引导后把堆接到 `AddressSpace`；保持 `heap.zig` 不直接 `import vm`（便于主机 `zig test`） |
| 池 zone | `src/mm/pool_zone.zig` | 按页 backing（可接 `setZoneBackingHooks`）；NonPaged/Paged 统计与虚拟窗文档常量 |
| Lookaside | `src/mm/lookaside.zig` + `percpu_index.zig` | per-CPU 小对象链；BSP 下标 0 |
| Ex 池封装 | `src/mm/ex_pool.zig` | `exAllocatePoolWithTag` / `exFreePoolWithTag` / **`exReallocatePoolWithTag`** → `pool.zig`（NT 公开名，行为子集） |
| 档位池 | `src/mm/pool.zig` | lookaside 热路径 + zone 页切片 + 全局档链 + **pool_gate**；tag 统计；超大档回退 `heap` |
| 伙伴（索引级） | `src/mm/buddy.zig` | `Buddy(max_order)`：按 `2^order` 连续块分配/合并；主机单测 |
| 物理伙伴封装 | `src/mm/phys_buddy.zig` | 自 `allocContiguous` carve arena；**`initKernelContiguousBuddy`** 在内核启动接线；`kernelAllocContiguousPhys` / `kernelFreeContiguousPhys` |
| Slab（小对象） | `src/mm/slab.zig` | 固定 `Obj` × `objects_per_slab`；单测经 **ex_pool** + `slab_pool_tag` |
| 物理 PFN | `src/mm/frame.zig` | **Free/Zeroed** 按 zone 双链表 O(1) 单页；位图 + 扫描用于连续块；`pfn_share_count` 供 CoW |
| 虚拟内存 | `src/mm/vm.zig` | 地址空间、lazy commit、`setSectionLazyCommitFillHook`、`tryCowWriteFault`（x86 `remapLeafPhysical`） |

## 伙伴 / slab 与通用堆分工

- **通用堆**：可变大小、合并降低碎片；大块与档位回退仍走此路径。
- **伙伴（物理）**：连续 PFN，供 DMA / 多页块；与位图单页分配并存；carve 失败时启动日志 `PhysBuddy: ... unavailable`。
- **Slab**：固定对象尺寸热路径；与 `pool` 档位互补。

算法均按公开教材描述实现，不参考 Windows/ReactOS 源码。

## 建议演进顺序

1. 保持 `heap` + `pool` + `buddy` + `slab` 主机单测绿；`heap.stats()`、`heap.freeListDebug()`、`heap.heap_check()` 用于调试。  
2. 压力场景下若碎片仍高，可评估 **TLSF** 或更强分离空闲链表（见教科书）。  
3. 将更多内核热点对象迁到 `SlabCache` + `ex_pool` tag，便于审计。

## 测试

- `zig build test`：`heap`、`pool`、`buddy`、`slab` 主机用例。  
- `phys_buddy` + `frame` + `arch` 的联合用例受 Zig「以 `src/mm/*.zig` 为根」模块路径限制，**未**单独加入 `zig build test`；算法由 `buddy.zig` 覆盖，**启动 klog** `PhysBuddy: contiguous arena leaf_pages=...` 用于接线确认。  
- 集成/回归亦可结合 QEMU 串口与 [NT61_KERNEL_TODO.md](NT61_KERNEL_TODO.md) K1 项。
