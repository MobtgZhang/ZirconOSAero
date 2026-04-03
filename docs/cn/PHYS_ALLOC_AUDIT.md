# 物理页分配审计（单一入口与内存图）

本文档记录 ZirconOSAero 内核 **物理帧** 来源与调用关系，作为 M1（伙伴/位图）整合的基线。

## 单一真理源

| 组件 | 路径 | 职责 |
|------|------|------|
| 位图帧分配器 | [`src/mm/frame.zig`](../../src/mm/frame.zig) | 自 Multiboot2 `mmap`（`BootInfo`）初始化可用帧；`alloc` / `free` / `allocContiguous`；可跟踪物理跨度由 **`-Dphys_track_gb=8\|16\|32\|64`** 决定（默认 **8**；大内存/Win7 Ultimate x64 档请显式 **16/32/64**，并注意 PFN 元数据 BSS 与主机单测栈占用） |
| 伙伴（逻辑） | [`src/mm/buddy.zig`](../../src/mm/buddy.zig) | 主机单元测试与算法参考 |
| 物理伙伴封装 | [`src/mm/phys_buddy.zig`](../../src/mm/phys_buddy.zig) | 从 `FrameAllocator.allocContiguous` carve `2^max_order` 页；`allocContiguousPagesWithSource` 对 **2 的幂**页数优先伙伴、否则回退位图（帧缓冲等释放须配对 `source`） |
| 虚拟映射回调 | [`src/mm/vm.zig`](../../src/mm/vm.zig) `allocFrameCb` | 页表页与匿名页均经 `FrameAllocator.allocZeroed` |

## 内存图（Multiboot2）

- 解析入口：[`src/boot/multiboot2_parse.zig`](../../src/boot/multiboot2_parse.zig)（仅 `MmapEntryType.available` 作为候选 RAM）。
- `FrameAllocator.init` 跳过：`< 1MiB`、内核映像、`mb_handoff` 区间、位图自身占用的物理页（见 `isReserved`）。另将 **reserved / ACPI reclaim / NVS / bad** 等条目的物理区间合并后，对「available」页做 **孔洞剔除**，减轻固件把设备内存标为 available 时 `memsetPhysicalPage` 写挂死的风险。
- **GOP 帧缓冲**：`BootInfo.fb_info` 经 `multiboot2_parse.gopPhysicalReserveRange` 得到页对齐区间，在 `isReserved` 中剔除，避免 `allocZeroed`→`memsetPhysicalPage` 误写显存（QEMU/实机常见 GPA 如 `0x80000000`）。
- **零页性能**：`memsetPhysicalPage` / `memcpyPhysicalPage` 在 x86_64 使用 `rep stosq` / `rep movsq`（无 SIMD），与 NT 6.1 API 无关、仅影响内核内部页清零耗时。

## 调用方（须经 `FrameAllocator`）

- 页表：`arch/*/paging.zig` 经 `vm` 的 `allocFrameCb`。
- 大缓冲区：VirtIO / 帧缓冲等通过 `kernel_frame_alloc` 或进程 `AddressSpace.allocator`。

## 断言与测试

- 启动后伙伴 arena（若启用）须 ⊆ firmware 可用区；不可用区（MMIO、ACPI NVS 等）不得出现在空闲位图中。
- 主机测试：`zig build test`（`buddy`、`heap`、`slab` 等）；`phys_buddy` 依赖完整 `arch` 模块树，仅在内核链接路径验证。
