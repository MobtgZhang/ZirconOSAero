# 启动三阶段与 NT 6.1 用户映像加载（里程碑边界）

本文档把 **物理帧种子**、**虚拟内存（VM）/页表** 与 **PE 用户态加载器** 三条线分开，避免与「卡在 Multiboot2 之后」等现象混淆。

## 启动三阶段（当前内核）

1. **Phase 1 — 帧种子（FrameAllocator.init）**  
   - 入口：Multiboot2 可用区经 `subtractNonRamFromRange` 打洞后，将 PFN 登记为 `free` 并挂入 dma/normal/high 空闲链。  
   - 性能要点：使用 `BootSeedReservedCache` 避免每 PFN 重复 `@intFromPtr`；连续区间用 `prependFreeRunInZone` 批量写位图与链表。  
   - 串口上位于 `Multiboot2: mem_lower=...` 与 `Frame allocator: total_frames=...` 之间。

2. **Phase 3 — VM / PML4（initAddressSpaceInPlace 等）**  
   - 从帧分配器取低地址可恒等映射的页建 PML4，再建立内核地址空间与 identity map。  
   - 依赖 Phase 1 已完成且 PFN 元数据一致。

3. **用户映像加载（NT 6.1 兼容，后续里程碑）**  
   - 与上两阶段独立：需要 `NtCreateSection` / `NtMapViewOfSection` 子集、PE32+ 头解析（见 `sdk/pe64_nt61.zig`）、重定位与用户栈。  
   - 进程侧预留字段见 `Process.image_base_address` / `peb_address`；用户 syscall 路径见 `ntdll.zig` 顶部注释与 `arch/x86_64/syscall*`。

## NT 6.1 二进制兼容（长线）

- **ABI**：公开 API 名与调用约定与 NT 6.1 对齐；实现为 clean-room。  
- **PE 布局**：以 Microsoft Learn「PE Format」为字段来源；布局测试在 `sdk/pe64_nt61.zig`。  
- **下一跳**：在 `section`/`vm`/`vad` 上实现最小映射闭环后，再接 `Ldr` 级导入与异常分发。
