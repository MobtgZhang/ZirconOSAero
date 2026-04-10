# NT 6.1 Virtual Memory and Display-Related ABI — Repository Correspondence

> This document only summarizes behavior from **Microsoft public documentation** and ZirconOSAero's current implementation; **no Windows source-level descriptions**. Clean-room only.

## Reference Sources (Whitelist)

- [NtAllocateVirtualMemory](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-zwallocatevirtualmemory) (kernel mode Zw/Nt symmetric)
- [Memory management constants](https://learn.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-virtualalloc) (user-mode VirtualAlloc MEM_* flags)

## NtAllocateVirtualMemory — Semantic Summary

| Concept | Public doc (summary) | Repository current state |
|---------|---------------------|-------------------------|
| Region reservation (Reserve) | Reserve VA range, no physical backing committed | Kernel `mm/vm.zig` primarily does page-table mapping; complete `MEM_RESERVE`/`MEM_COMMIT` two-phase semantics still evolving |
| Commit | Allocate actual backing store (page file / physical pages) | `mapPageAlloc` / `mapRange` equivalent to committed leaf mapping; `VirtualCommitPhase` enum marks Reserve/Commit roadmap |
| Protection attributes | PAGE_READWRITE etc. | Map flags: `vm.MapFlags` (writable/executable/uncached) |

## Framebuffer and High Resolution

- **UEFI GOP / ramfb hand-off**: physical address and `pitch × height` must fall within mappable range; x86_64 and LoongArch have `mapIdentityByteRange` to cover FB tail not covered by identity mapping.
- **Dual-buffer upper bound**: `BACK_BUF_MAX` in `framebuffer.zig`; overflow triggers logging and degrade strategy.
- **LoongArch ramfb**: uses `kernel_preferred_fb_width/height` consistent with build (`build.conf` / Makefile `ZBM_FB_OPTS`), avoids fixed 1024×768 mismatch.

## Delay and Tick (`NtDelayExecution` / Sleep)

| Concept | Public doc (summary) | Repository current state |
|---------|---------------------|-------------------------|
| Relative delay (negative `DelayInterval` in 100ns units) | Kernel sleeps on preemptible path until expiration | Many paths use **`scheduler.yield`** or tick-driven wait as **approximation**; HPET-level high-precision sleep **not** implemented |
| **Actual granularity** | NT depends on timer resolution | Primary path: **PIC + PIT ~100 Hz**, so visible delays are typically **~10 ms** (whole tick alignment). High-resolution path: [TimerPrecisionRoadmap.md](../cn/TimerPrecisionRoadmap.md) and `ke/timekeeping.zig` |

## NtLockVirtualMemory / NtUnlockVirtualMemory

Currently **stubs that return success** (do not change working set or MDL); SSDT uses folded slots **0x53 / 0x54** (see [SyscallABI.md](../cn/SyscallABI.md)). Production semantics and Working Set management are on roadmap.
