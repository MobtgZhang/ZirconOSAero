# PFN 引用计数与 map/unmap 一致性（路线图）

本文档描述 ZirconOSAero 内核中 **物理页帧（PFN）引用** 与 **虚拟映射** 逐步对齐的计划，供审计与阶段一收尾对照（`content7.4.md` / K1.x）。

## 现状摘要

- **CoW / fork**：`duplicateUserMappingsForFork`、`tryCowWriteFault` 路径对部分用户私有页维护共享与分裂语义；引用与 `FrameAllocator` 的对接以该路径为主。
- **普通 `mapPageAlloc` / `unmapAndFree`**：部分路径以 VAD/节区视图元数据为主，**尚未**在每一对 map/unmap 上统一递增/递减 PFN 级引用计数。
- **非 x86_64**：`remapLeafPhysical` 等与体系结构相关的 dup/CoW 能力见架构支持矩阵（`NT61_CONTRACT_MATRIX.md`）。

## 目标状态（里程碑）

1. **单一策略文档化**：在 `map`、`unmap`、`releaseProcessAddressSpace`、节区惰性提交填页四条路径上，明确「谁持有 PFN 引用」。
2. **引用与 VAD 一致**：每个已提交用户 PTE 对应至少一条可追踪的 PFN 引用；`unmapRange` 与进程销毁时成对释放。
3. **与 WRITECOPY 文件视图衔接**：真 COW 实现后，只读映射共享同一 PFN，首次写时分裂并调整引用计数。

## 非目标（当前迭代）

- 不引入 Windows/ReactOS 式 PFN 数据库完整克隆；以本仓库 `FrameAllocator` + VAD/视图表为真源逐步演进。

## 相关

- 物理页 **可用区过滤**（含 GOP 排除）：[`PHYS_ALLOC_AUDIT.md`](PHYS_ALLOC_AUDIT.md)、[`src/mm/frame.zig`](../../src/mm/frame.zig) `fb_reserve_*`。
