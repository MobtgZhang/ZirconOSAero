# NT 6.1 Kernel and User-Mode: Implementation Status and Verification Entry Points

> **Authority**: [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) and [NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md) for details.

This document summarizes the **honest current focus** of each major area — memory/HAL, process/syscalls, filesystem/PE/Win32 — and **how to verify** each. See the contract matrix for exact status per capability.

## How to Run Automated Verification

```bash
zig build test                    # Host-side unit tests (heap, pool, SSDT, IRP, VFS constants, etc.)
bash scripts/ci-qemu-smoke.sh     # x86_64 ZBM MBR serial smoke (requires local QEMU + build artifacts)
python3 tests/run_all.py          # Python suite (boot combos, Multiboot2 headers, etc.)
```

GitHub Actions: `.github/workflows/ci.yml` (multi-arch `zig build kernel`, ZBM UEFI artifacts).

## D1–D2: Memory Management, Interrupts, and HAL

| Area | Current State (Summary) | Tracking Doc / Code |
|------|------------------------|---------------------|
| Physical frames / mmap | Multiboot2 (ZBM handoff) drives `frame.zig`; `-Dphys_track_gb` extends trackable RAM upper bound; buddy + contiguous frame buffer pages | `src/mm/frame.zig`, `phys_buddy.zig` |
| Pool and heap | Bump + reclaim + `mm/pool` size classes; slab/buddy evolution | [MM_HEAP_POOL_SLAB.md](../cn/MM_HEAP_POOL_SLAB.md) |
| Paging / isolation | 4-level tables, identity mapping; per-process CR3 and mitigations in matrix | `src/arch/*/paging*` |
| Interrupts / timers | x86_64: PIC+PIT primary tick; `ke/timekeeping.zig` abstraction; HPET MMIO probe/read-only (not wired to IRQ0); LAPIC one-shot tick T3; SMP AP real path K2.4 | [TimerPrecisionRoadmap.md](../cn/TimerPrecisionRoadmap.md), [NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md) K2–K3 |
| Graphics / VirtIO-GPU | VirtIO: `SET_SCANOUT` + `RESOURCE_FLUSH`; **Phase 4**: `-Dforce_gop_present`, `CompositorBackend`, `open_desktop` LPC; NVIDIA: BAR logging + optional prefetchable BAR 4MiB mapping | [AeroDesktopRuntime.md](AeroDesktopRuntime.md) §8, [SOFTWARE_COMPOSITOR_WDDM.md](../cn/SOFTWARE_COMPOSITOR_WDDM.md) |
| Other architectures | aarch64 / riscv64 / loongarch64: vectors, timers, device tree or firmware handoff differ per arch | `src/arch/<arch>/`, [Boot.md](Boot.md), [TIER2_ARCHITECTURES.md](../cn/TIER2_ARCHITECTURES.md) |

**Backlog anchors**: NT61_KERNEL_TODO **K1, K2, K3**.

## D3–D4: Process, Scheduler, Nt-Style Syscall

| Area | Current State (Summary) | Tracking Doc / Code |
|------|------------------------|---------------------|
| Scheduler | Per-CPU **32**-level FIFO ready buckets + timeslice/starvation/I/O boost; mutex inheritance **depth pairing**; thread table default **64** slots (`-Dmax_scheduler_threads=`); NUMA/full IRQL **explicitly not short-term** | [SCHEDULER_API.md](../cn/SCHEDULER_API.md), `src/ke/scheduler.zig` |
| Process / thread | Process Server, object path partially usable | `src/ps/`, contract matrix §0 |
| Syscall | x86_64: `syscall` + SSDT subset; VM/section dispatch split to `syscall_dispatch_mm.zig`; CR3 refresh before returning to user | [SyscallABI.md](../cn/SyscallABI.md), `ssdt_nt61.zig` |
| ntdll alignment | Service numbers and stub functions continuously aligned with SSDT | `src/libs/ntdll/`, K7 |

**Backlog anchors**: NT61_KERNEL_TODO **K2, K7**.

## D5–D7: FAT32, VFS, PE, Minimal Win32

| Area | Current State (Summary) | Tracking Doc / Code |
|------|------------------------|---------------------|
| VFS / FAT32 | Mount and main path; no goal of Windows-format interoperability | `src/fs/` |
| NTFS | **Subset** (MFT basic path); full features are long-term roadmap | README feature matrix, contract matrix |
| PE32+ | Headers, imports, relocations, PEB/TEB **subset** | `src/loader/` |
| kernel32 / user32 | Subset; Aero and DWM are partial implementations | Contract matrix, DesktopManagerSpec |

**Principle**: **Stabilize FAT32 + static PE first**, then extend NTFS read-only/subset; **WOW64 / full Aero** are long-term goals. See [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md).

## mips64el

Experimental architecture, **not** at the same commitment level as x86_64 / aarch64 / riscv64 / loongarch64. See [TIER2_ARCHITECTURES.md](../cn/TIER2_ARCHITECTURES.md), [Boot.md](Boot.md).
