# NT 6.1 风格内存管理 — LoongArch64「新世界」QEMU virt / UEFI（原创规格）

本文件描述 ZirconOSAero 在 **LoongArch64、QEMU `virt`、低地址恒等映射内核** 下的 **NT6.1 行为对齐**（机制与策略边界），**不**复制 WDK/微软头文件。实现以 `src/arch/loongarch64/paging.zig` 与 `src/mm/vm.zig` 为准。中文姊妹篇：`docs/cn/MemoryManagement_NT61_LoongArch64_NewWorld.md`。

## 1. 虚拟地址与链接模型（与 `link/loongarch64.ld` 一致）

- 内核映像链接 **VA = 0x0020_0000**，落在首段 RAM；**禁止**把内核 `PhysAddr` 伪装成 `0x9000…` 等固件未映射的高位窗口（见链接脚本注释）。
- 引导阶段在内核自有页表中建立 **identity**（`virt == phys`），供 MMIO、VirtIO 等与 x86 恒等策略同构。
- 用户态可执行映像与堆栈的 VA 策略与 NT x64 **数值上兼容**：`USER_VA_MIN_LA_NT` .. `USER_VA_MAX_LA_NT` 与 x64 NT 用户区上下界一致（见 `vm.zig` 常量），便于子系统与测试共享矩阵。

## 2. 页表：三级、16KiB 叶

- **根表（PGD）**：2048 项 × 8B = 16KiB；每项覆盖 **64GiB** VA（2^{11+11+14} 字节）。
- **L1 / L2**：同样 2048 项；**叶**在 L2，页大小 `**page_size = 16384`**。
- VA 分解（与 `VirtAddr` 一致）：
  - `L0 index` = VA[47:36] 中低 11 位（`>> 36 & 0x7FF`）
  - `L1 index` = VA[35:25] 低 11 位
  - `L2 index` = VA[24:14] 低 11 位
- **大页 / 块映射**：`mapIdentity32MiBlock` 在单张 L2 表中连续填 2048×16KiB 叶；`forEachUser4KiPresentLeaf` **仅枚举 16KiB 叶**（名称保留以与 x86 API 一致）。

## 3. 叶 PTE 标志（公开手册语义，非 WDK）

- `V`：有效  
- `D`：脏 / 可写侧语义与 `mapPage` 标志 `Write` 对齐  
- `PLV[3:2]`：特权级；**用户叶**须为 `PLV_USER`（`3<<2`）  
- `MAT[5:4]`：缓存属性；`MAT_CC` / `MAT_WUC`（MMIO）等  
- `NX`、`NR`、`RPLV`：与实现一致时使用

**用户叶判定**（fork / 枚举）：`(raw & (3<<2)) == PLV_USER`。

## 4. 用户半区 vs 内核半区（与 x86 PML4 0..256 / 256..512 **概念**对齐）

为与 `vm.releaseProcessAddressSpace` / `linkKernelHalfMappings` 共用同一套策略：


| 概念（x86_64）            | LoongArch64 实现           |
| --------------------- | ------------------------ |
| 用户半区 PML4 索引 0..256   | **PGD 索引 0..1023**（含）    |
| 内核半区 PML4 索引 256..512 | **PGD 索引 1024..2047**（含） |


- `**releaseUserHalfAddressSpace`**：仅拆除 **PGD[0..1024)** 子树并释放其 **叶帧与中间表帧**；**绝不**释放 **PGD[1024..2048)**，以免破坏与内核根表共享的内核侧映射副本。
- `**linkKernelHalfMappings`**：将内核 `AddressSpace` 的 **PGD[1024..2048]** 项 **按项复制**到进程 PGD（与 x86 复制 PML4 高半区同理：共享所指中间表/叶物理帧，不深度拷贝整棵树）。

### 4.1 与当前内核低 VA 的说明（调度 / PGDL）

当前内核代码与恒等映射主要落在 **PGD[0]** 子树（低 VA）。**内核**的 `AddressSpace` 与**进程**的 `AddressSpace` 各自持有独立 PGD 物理页：

- 进程的 **PGD[0..1024)** 仅承载 **用户**映射；**不**与内核 PGD 共享 L0[0] 子树，因此进程退出时释放用户半区 **不会**拆掉内核恒等映射。
- 进程的 **PGD[1024..2047]** 与内核对齐，用于将来在高位窗口挂内核可见映射（或双根方案演进）；若内核尚未填充高索引项，复制结果为空槽，不影响当前行为。
- **调度器**：`ke/scheduler.zig` 的 `activateCr3ForProcessId` 在 **x86_64** 与 **loongarch64** 上均生效：有 `address_space` 的进程被调度到时调用 `AddressSpace.activate()` → `paging.loadCr3`（LoongArch 为 CSR **0x18**），与 x86「高半区共享 + 低半区私有」的最终形态一致。
- **系统调用返回**：x86 在 `arch/x86_64/syscall.zig` 返用户前再次 `activate` 当前进程地址空间；LoongArch 用户态 syscall 出口若后续落地，应在返用户前做 **同等** `activate`，与调度器切换互补（见 `docs/cn/VM_ISOLATION.md` 思路）。

## 5. CSR：页表根与 TLB

- `**csrwr val, 0x18`**：加载当前根表物理地址（与树中 `loadCr3` 命名对齐）；具体 CSR 助记与手册一致即可。
- **`loadCr3`（freestanding）**：写入 CSR **0x18** 后，若根物理地址与上次装载相同则 **跳过** `INVTLB_ALL`；在 **当前已装载** 根表上完成 `mapPage`/`unmapPage`/`protectLeafPage`/`remapLeafPhysical`/`mapIdentity32MiBlock` 等变更时须调用 `paging.noteCurrentPageTablePossiblyMutated(pgd_phys)`，否则不得省略全局失效。单页路径仍用 `invtlb 0x6`（按 VA）。**ASID** 与多核 IPI shootdown 仍为后续项（见 `hal/loongarch64/tlb_flush.zig`）。
- **TLB**：软件管理 TLB；修改叶映射后须失效相关项。
  - **全局**：`invtlb 0x0, $zero, $zero`（`INVTLB_ALL`）。
  - **按 VA**：`invtlb 0x6, $zero, va`（`INVTLB_ADDR_GTRUE_OR_ASID`，ASID=0；与 Linux `invtlb_addr` 宿主路径一致）。大块 `mapIdentity32MiBlock` 末尾仍可用全局失效。
- **ASID**：与 x86 PCID **概念**对齐；本阶段可不实现 ASID 轮换，规格保留扩展位。
- **释放用户地址空间**（`vm.releaseProcessAddressSpace`）：LoongArch freestanding 路径调用 `hal/loongarch64/tlb_flush.zig`（与 x86 `tlb_broadcast` **接口形状**对齐：`notePendingGlobalShootdown`、`noteUserMappingInvalidatedSmp`、`requestGlobalFlushStub`）。当前为 **单核本地** 全 TLB 刷新；多核 IPI 策略待扩展。

## 6. DMW 窗口（仅边界）

内核可能使用 **DMW** 直接映射窗口（如 `0x8000…` / `0x9000…`）访问特定物理区间；**本规格不**把 NT 用户 VA 策略强加到 DMW。用户普通映射仍须通过 **PGD 遍历路径**并受 `userVaRangeAllowedLa64` 约束。

## 7. `unmapPage` 与中间表

当前实现 **不**在单页 `unmapPage` 时收缩空的 L1/L2 表（与部分架构最小实现一致）。**叶物理帧**由 `vm.unmapPage` / `unmapAndFree` 等上层决定是否 `FrameAllocator.free`，与 x86 分层一致。若未来与 x86 行为对齐表收缩，应在规格本节更新并补充测试。

## 8. 回归矩阵（主机 + QEMU）


| 项                                    | 方式                                                                                                    |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| VA 分解 / 64GiB 每 L0 槽                 | `tests/host/loongarch_nt61_mm_host.zig`（`src/loongarch_nt61_mm_host.zig` 为符号链接）                                                                      |
| NT 用户 VA 上下界（LA 常量）                  | `tests/host/loongarch_nt61_mm_host.zig` + `tests/host/vm_user_va_policy_nt61_host.zig` + `src/mm/vm_user_va_policy.zig` + `userVaRangeAllowedLa64`          |
| LoongArch 叶 PTE 位布局（主机锚点）            | `tests/host/loongarch_nt61_mm_host.zig`（`protectLeafPage` 行为测在 LoongArch 目标的 `paging.zig`）                |
| `protectLeafPage` / `protectVirtualRange` | `src/arch/loongarch64/paging.zig` + `vm.zig`；目标测试见 `paging.zig`                                           |
| 调度器切换 PGDL                         | `src/ke/scheduler.zig` `activateCr3ForProcessId`；QEMU 烟测                                              |
| `releaseProcessAddressSpace` TLB 占位   | `src/hal/loongarch64/tlb_flush.zig` + `vm.zig`                                                         |
| `releaseUserHalf` 不碰 PGD[1024..2048) | LoongArch 目标上 `paging.zig` 内建测试（或未来 cross-test）                                                       |
| fork / CoW                           | `@hasDecl(forEachUser4KiPresentLeaf)` / `remapLeafPhysical` 接线后，沿用 `fork_cow_share_nt61_host` 与内核串口用例 |
| QEMU loongarch64 virt                | 进程创建/退出、映射后访问用户缓冲；详见里程碑文档；中文说明见 `docs/cn/MemoryManagement_NT61_LoongArch64_NewWorld.md`      |


---

*变更页表遍历、TLB 失效、半区释放或 `vm` 用户 VA 策略时，须同步更新本节并运行相关测试。*