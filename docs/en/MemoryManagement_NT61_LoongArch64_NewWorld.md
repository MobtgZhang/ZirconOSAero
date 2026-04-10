# NT 6.1 Memory Management — LoongArch64 "New World" QEMU virt / UEFI (English Sibling)

> **Maintained in sync with Chinese version** `cn/MemoryManagement_NT61_LoongArch64_NewWorld.md`. Describes NT 6.1 **observable behavior** boundaries for ZirconOSAero on **LoongArch64, QEMU `virt`, low-address identity-mapped kernel**. **Does not** replicate WDK/Microsoft headers. Implementation authority: `src/arch/loongarch64/paging.zig` and `src/mm/vm.zig`.

Lazy commit, VAD, and fork/CoW matrix: see [MVT_NT61.md](MVT_NT61.md).

---

## Comparison with x86_64 (Reducing Cognitive Bias During Implementation)

| x86_64 | LoongArch64 this tree |
|---------|----------------------|
| 4-level page tables, 4KiB leaf | **3-level** page tables (PGD→L1→L2), **16KiB leaf** |
| PML4 index **0..255** user half | PGD index **0..1023** user half |
| PML4 index **256..511** shared high-half entries | PGD index **1024..2047** aligned with kernel |
| `CR3` load root table physical address | **CSR 0x18** (`loadCr3` same-name wrapper) |
| `invlpg` / PCID / IPI shootdown (x86 HAL) | Software TLB: `invtlb` by VA or global; release path: `hal/loongarch64/tlb_flush.zig` |
| `forEachUser4KiPresentLeaf` (name historical legacy) | Enumerates **16KiB** user leaves; API name unchanged |

---

## 1. Virtual Address and Link Model (Consistent with `link/loongarch64.ld`)

- Kernel image linked at **VA = 0x0020_0000**, in first RAM segment; **prohibited** to fake kernel `PhysAddr` as high unmapped firmware window.
- Boot phase establishes **identity** (`virt == phys`) in kernel's own page table for MMIO, VirtIO, etc. — isomorphic to x86 identity strategy.
- User VA bounds match NT x64 **numerically**: `USER_VA_MIN_LA_NT` .. `USER_VA_MAX_LA_NT` (defined in `vm.zig`), convenient for subsystems and tests.

---

## 2. Page Tables: Three-Level, 16KiB Leaf

- **Root table (PGD)**: 2048 entries × 8B = 16KiB; each entry covers **64GiB** VA.
- **L1 / L2**: 2048 entries; **leaf** at L2, `page_size = 16384`.
- VA decomposition: `L0/L1/L2` indices each 11 bits (**do not truncate 2048 entries with `u9`**).
- **Block mapping**: `mapIdentity32MiBlock` fills a 32MiB-aligned block at once (2048×16KiB).

---

## 3. Leaf PTE Flags (Public Manual Semantics)

- `V`: Valid
- `D`: aligned with Write semantics
- `PLV[3:2]`: user leaf = `PLV_USER`
- `MAT[5:4]`: `MAT_CC` / `MAT_WUC` (MMIO) etc.
- `NX`, `NR`, `RPLV`: used per implementation

**User leaf判定** (fork / enumeration): `(raw & (3<<2)) == PLV_USER`.

**Protection update**: `protectLeafPage` aligned with `vm.protectVirtualRange` / `ZwProtectVirtualMemory` hardware subset (no x86-style large page split).

---

## 4. User Half vs. Kernel Half

| Concept (x86_64) | LoongArch64 |
|------------------|------------|
| User half PML4 0..1023 | PGD **0..1023** |
| Kernel half PML4 1024..2047 | PGD **1024..2047** |

- **`releaseUserHalfAddressSpace`**: tears down **only PGD[0..1024)**, **never** release **PGD[1024..2048)**.
- **PGDL switch for scheduler**: `AddressSpace.activate()` calls `tlb_la.activateAsid(asp.asid)` + version check + `kpcr.setCurrentAsid(asid)`.
- **User syscall exit**: currently **not** doing `activate` before returning to user; to be added per `arch/loongarch64/syscall_dispatch.zig`.

---

## 5. CSR / TLB / Release Path

- **CSR 0x18** (PGD root): loaded by `loadCr3` during context switch and AP bring-up.
- **`invtlb`** family: `invtlb_all`, `invtlb_addr_va`, `invtlb_all_asid`. Implementation: `hal/loongarch64/tlb_flush.zig`.
- **ASID**: bitmap allocation in `tlb_la.allocAsid()`; release via `tlb_la.releaseAsid(asid)`; version bump via `tlb_la.bumpAsidVersion()`. Per-CPU ASID table in `kpcr.current_asid`.
- **Implementation index**: see `hal/loongarch64/tlb_flush.zig`, `mm/vm.zig`, `ps/process.zig`, `arch/loongarch64/paging.zig`; host test: **`loongarch_nt61_mm_host`** (**K1.8 Verified**).

---

## 6. PEB / TEB / TLS on LoongArch64

### Native LA64 Process

User VA band is **numerically compatible** with x64 (see `USER_VA_MIN_LA_NT` .. `USER_VA_MAX_LA_NT` in `vm.zig`). PEB/TEB field layout can reuse subsets from `peb_nt61_x64.zig` / `teb_nt61_x64.zig`; test against host anchors.

### Future WOW64 (x86-32)

32-bit PEB/TEB pointer and `ProcessWow64Information` behavior consistent with x86_64 host (conceptual level, see MS Learn); implementation must be independent.

### TLS

Static TLS directory still gated by `pe.zig` strategy; no LoongArch-specific exceptions.

### Testing

When adding layout assertions, prioritize **host tests** + `builtin.cpu.arch == .loongarch64` builtin tests; avoid introducing closed-source headers.
