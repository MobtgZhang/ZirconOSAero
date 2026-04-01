# 内核堆、池与后续 slab/伙伴（边界说明）

## 当前实现（与代码一致）

| 组件 | 路径 | 职责 |
|------|------|------|
| 通用堆 | `src/mm/heap.zig` | bump 增长区；每块带 `FreeBlock` 头；`alloc` / `kfree`；**不**做相邻空闲块合并 |
| 档位池 | `src/mm/pool.zig` | 16–512 字节固定档 + 每档空闲链表；超大档回退到 `heap`；语义对齐 NonPagedPool **子集**（slab 化小对象热路径） |
| 伙伴（索引级） | `src/mm/buddy.zig` | `Buddy(max_order)`：按 `2^order` 连续块分配/合并；**当前**为主机单测 + 将来可包裹 `frame.zig` 连续物理页需求 |
| 物理帧位图 | `src/mm/frame.zig` | 全机物理页位图 + `alloc` / `allocContiguous` 线性扫描；与 `buddy.zig` 整合属后续里程碑 |
| 虚拟内存 | `src/mm/vm.zig` | 地址空间、映射/取消映射、lazy commit；与堆正交 |

## 为何尚未上伙伴 / slab

- **伙伴系统**：适合按 2^k 合并、降低外部碎片；需替换或包裹当前空闲链表策略，并增加 O(log n) 或位图维护成本。
- **Slab**：适合固定对象尺寸（`KTHREAD`、小 `IRP` 等）；与现有 `pool` 档位可渐进合并为统一 slab 层。

二者均属公开教材级算法，实现时仅依据教科书/论文描述，不参考 Windows/ReactOS 源码。

## 建议演进顺序

1. 保持 `heap` + `pool` 的单元测试与契约矩阵一致。  
2. 在压力场景（大量小对象交错释放）下测量碎片；若 `heap_pos` 逼近 `HEAP_SIZE` 再引入伙伴或分离空闲链表。  
3. 将热点小对象（句柄表节点等）迁移到专用 slab 档，减少通用堆压力。

## 测试

- `zig build test`：`heap`、`pool`、`buddy` 主机用例。
