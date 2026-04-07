# NT 6.1 风格内存管理 — LoongArch64「新世界」QEMU virt / UEFI（中文姊妹篇）

本文档与英文规格 [MemoryManagement_NT61_LoongArch64_NewWorld.md](../specs/MemoryManagement_NT61_LoongArch64_NewWorld.md) **同步维护**：描述 ZirconOSAero 在 **LoongArch64、QEMU `virt`、低地址恒等映射内核** 下的 NT6.1 **可观测行为**边界；**不**复制 WDK/微软头文件。实现以 `src/arch/loongarch64/paging.zig` 与 `src/mm/vm.zig` 为准。

惰性提交、VAD 与 fork/CoW 矩阵另见 [MVT_NT61.md](MVT_NT61.md)。

---

## 与 x86_64 概念对照（减少重复实现时的认知偏差）

| x86_64 | LoongArch64 本树实现 |
|--------|---------------------|
| 4 级页表，4KiB 叶 | **3 级**页表（PGD→L1→L2），**16KiB 叶** |
| PML4 索引 **0..255** 用户半区 | PGD 索引 **0..1023** 用户半区 |
| PML4 索引 **256..511** 与内核共享的高半区入口 | PGD 索引 **1024..2047** 与内核对齐复制 |
| `CR3` 加载根表物理地址 | **CSR 0x18**（代码中 `loadCr3` 同名封装） |
| `invlpg` / PCID / IPI shootdown（x86 HAL） | 软件 TLB：`invtlb` 按 VA 或全局；释放路径见 `hal/loongarch64/tlb_flush.zig` |
| `forEachUser4KiPresentLeaf`（名称历史遗留） | 枚举 **16KiB** 用户叶，API 名不变 |

---

## 1. 虚拟地址与链接模型（与 `link/loongarch64.ld` 一致）

- 内核映像链接 **VA = 0x0020_0000**，落在首段 RAM；**禁止**把内核 `PhysAddr` 伪装成固件未映射的高位窗口（见链接脚本注释）。
- 引导阶段在内核自有页表中建立 **identity**（`virt == phys`），供 MMIO、VirtIO 等与 x86 恒等策略同构。
- 用户区 VA 上下界与 NT x64 **数值一致**：`USER_VA_MIN_LA_NT` .. `USER_VA_MAX_LA_NT`（定义在 `vm.zig`），便于子系统与测试共用策略。

---

## 2. 页表：三级、16KiB 叶

- **根表（PGD）**：2048 项 × 8B = 16KiB；每项覆盖 **64GiB** VA。
- **L1 / L2**：2048 项；**叶**在 L2，`page_size = 16384`。
- VA 分解与 `VirtAddr` 一致：`L0/L1/L2` 索引各 11 位（**勿用 `u9`** 截断 2048 项）。
- **块映射**：`mapIdentity32MiBlock` 一次填满 32MiB 对齐块（2048×16KiB）。

---

## 3. 叶 PTE 标志（公开手册语义）

- `V`：有效  
- `D`：与可写语义对齐（`Write`）  
- `PLV[3:2]`：用户叶为 `PLV_USER`  
- `MAT[5:4]`：`MAT_CC` / `MAT_WUC`（MMIO）等  
- `NX`、`NR`、`RPLV`：按实现使用  

**用户叶判定**（fork / 枚举）：`(raw & (3<<2)) == PLV_USER`。

**保护位更新**：`protectLeafPage` 与 `vm.protectVirtualRange` / `ZwProtectVirtualMemory` 硬件侧子集对齐（无 x86 式大页拆分）。

---

## 4. 用户半区 vs 内核半区

| 概念（x86_64） | LoongArch64 |
|----------------|------------|
| 用户半区 PML4 0..256 | PGD **0..1023** |
| 内核半区 PML4 256..512 | PGD **1024..2047** |

- **`releaseUserHalfAddressSpace`**：只拆 **PGD[0..1024)**，**绝不**释放 **PGD[1024..2048)**。  
- **`linkKernelHalfMappings`**：把内核根表的 **PGD[1024..2048]** 按项复制到进程 PGD（共享子树物理帧，不深拷贝）。

### 4.1 调度与 PGDL（页表根）

- **内核**与**进程**各自持有独立 PGD；进程用户映射只挂在 **PGD[0..1024)**，退出用户半区时不会拆掉内核恒等映射。
- **`activateCr3ForProcessId`**（`ke/scheduler.zig`）在 **x86_64 与 loongarch64** 上均会切换根表：进程有 `address_space` 时调用 `AddressSpace.activate()` → `paging.loadCr3`。
- **LoongArch `loadCr3`**（freestanding）：写 CSR 0x18 后，若根物理与上次相同则 **跳过** 全局 `invtlb`；当前已装载根表被 `mapPage`/`unmapPage` 等改动时需 `noteCurrentPageTablePossiblyMutated`，单页仍按 VA `invtlb`。ASID/多核 IPI 见英文规格 §5 与 `hal/loongarch64/tlb_flush.zig`。
- **系统调用返回**：x86 在 `arch/x86_64/syscall.zig` 返用户前再次 `activate` 进程空间；LoongArch 若引入用户 syscall 出口，应 **同样** 在返回用户前对齐 PGDL（与调度器切换互补）。

---

## 5. CSR、TLB 与释放路径

- **根表**：`csrwr val, 0x18`（与 `loadCr3` 命名对齐）。
- **修改映射**：单页路径多用按 VA 的 `invtlb`；大块 identity 可用全局 `invtlb`。
- **`vm.releaseProcessAddressSpace`**（LoongArch freestanding）：在拆除用户半区前后调用 `hal/loongarch64/tlb_flush.zig` 的 `notePendingGlobalShootdown` / `noteUserMappingInvalidatedSmp` / `requestGlobalFlushStub`（当前 **BSP 本地** `invtlb` 全刷；多核 IPI 策略待与 x86 K2.5 同级扩展）。

---

## 6. DMW 窗口（仅边界）

内核可使用 **DMW** 直接映射窗口访问部分物理区间；**不**将 NT 用户 VA 策略强加于 DMW。用户普通映射须走 PGD 并满足 `userVaRangeAllowedLa64`。

---

## 7. `unmapPage` 与中间表

单页 `unmapPage` **不**收缩空的 L1/L2；**不**在此路径释放叶物理帧（与 `vm.unmapAndFree` 分层一致）。若未来与 x86 完全对齐收缩策略，须更新**英/中**规格并加测。

---

## 8. 实现索引（行为 → 符号 → 验证）

| 行为 | 主要符号 | 验证 |
|------|----------|------|
| VA 分解 / 64GiB/L0 | `VirtAddr`、`loongarch_nt61_mm_host` | `zig build test` |
| NT 用户 VA 带 | `userVaRangeAllowedLa64` | `loongarch_nt61_mm_host`、`vm_user_va_policy_nt61_host`（LA 相关断言） |
| 半区释放不碰内核槽 | `releaseUserHalfAddressSpace` | `paging.zig` 目标测试（LA） |
| 叶保护 | `protectLeafPage` | `paging.zig` 目标测试（LA）；主机位布局锚点 `loongarch_nt61_mm_host` |
| 调度切换根表 | `activateCr3ForProcessId`、`AddressSpace.activate` | QEMU 进程切换 |
| 释放后 TLB | `hal/loongarch64/tlb_flush.zig` | 与 `vm.releaseProcessAddressSpace` 联调 |
| fork / CoW | `forEachUser4KiPresentLeaf`、`remapLeafPhysical` | `fork_cow_share_nt61_host` + 内核用例 |

---

## 9. 手工 / QEMU 烟测（建议）

1. 构建并运行 **loongarch64 virt** 目标（见根目录 `Makefile` / README）。  
2. 创建用户进程，映射用户缓冲，验证读写与切换后仍正确。  
3. 进程退出后无页表 UAF（无其它线程挂旧 PGDL）。

---

*变更页表遍历、TLB、半区释放或用户 VA 策略时，须**同时**更新英文 `docs/specs/...` 与本文件，并运行相关测试。*
