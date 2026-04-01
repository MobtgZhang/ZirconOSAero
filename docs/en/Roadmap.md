# ZirconOSAero roadmap

**Implementation status** is **not** implied by the phase list below. Use [NT61_CONTRACT_MATRIX.md](../cn/NT61_CONTRACT_MATRIX.md) and [API_COMPAT_MATRIX.md](../cn/API_COMPAT_MATRIX.md) as the single source of truth (`Stub` / `Partial` / `Done` / `Verified`).

## 1. Goal layers

### Level 1 — Kernel usable

Core microkernel features so the system boots and runs reliably:

- x86_64 boot (BIOS + UEFI)
- Basic virtual memory and paging
- Interrupts and timer
- Thread scheduler
- IPC
- User-mode processes
- System calls

### Level 2 — NT-style kernel model

Architecture beyond a typical hobby OS:

- Object Manager + handle table
- Process/thread/token/port object model
- LPC-style IPC
- IRP-style I/O framework
- Session/subsystem architecture
- Security (token/SID/ACL)

### Level 3 — Win32 compatibility

On top of a stable kernel:

- PE loader (PE32 + PE32+)
- ntdll (Native API)
- kernel32 subset
- csrss-style subsystem server
- user32 / gdi32
- WOW64
- CMD in kernel; advanced shell via planned user-mode .NET host

## 2. Milestones (Phase 0–11)

Phase headings describe **scope**, not “all done”. See the contract matrix for each subsystem.

### Phase 0 — Tooling

- Zig cross-compilation (CI pins **Zig 0.15.2**; see `docs/REPRODUCE_BUILD.md`)
- QEMU debugging
- Serial logging
- Build system (`build.zig` / optional Makefile / `run.sh`)

### Phase 1 — Boot + early kernel

- **ZBM only** in this repo (BIOS/MBR + UEFI)
- Multiboot2 handoff where used (x86_64)
- UEFI boot application
- GDT/TSS
- Physical memory discovery + frame allocator
- Kernel heap (bump growth + per-block free list + `mm/pool` size classes; buddy/slab roadmap: `docs/cn/MM_HEAP_POOL_SLAB.md`)
- VGA text + serial

### Phase 2 — Interrupts / timer / scheduler

- IDT (256 vectors)
- PIC + PIT (~100 Hz)
- Preemptive **multi-priority** ready queues (not NT 32-level; see `docs/cn/SCHEDULER_API.md`)
- Keyboard/mouse drivers (platform-dependent; many paths still partial)
- Sync primitives (spinlock, event, mutex, semaphore)

### Phase 3 — Virtual memory

- Four-level page tables
- Identity mapping
- Framebuffer mapping
- User/kernel separation
- Page table switches

### Phase 4 — Objects / handles / process core

- Object Manager (headers, types, namespace)
- Per-process handle tables
- Process/thread objects
- Security tokens
- Waitable objects

### Phase 5 — IPC + services

- LPC ports
- Synchronous request/reply
- Process Server (PID 1)
- Session Manager / SMSS (PID 2)
- System LPC port registration

### Phase 6 — I/O + filesystem + drivers

- I/O Manager (driver/device/IRP)
- VFS
- FAT32 (`C:\`)
- NTFS (`D:\`)
- Registry (in-memory subset; hive persistence planned)
- Video / framebuffer path partial; **ACPI / PCIe / USB / full audio** — see roadmap “Next steps”

### Phase 7 — Loaders

- ELF64 loader
- PE32+ loader
- PE32 loader
- DLL loading and import resolution
- Base relocations

### Phase 8 — Userland foundation

- ntdll (Native API **subset**)
- kernel32 (Win32 base **subset**)
- Console runtime
- CMD
- Managed shell: planned **.NET** user-mode host (not in this repo)

### Phase 9 — Win32 subsystem

- csrss server
- Win32 execution engine
- PE load + DLL binding
- Process lifecycle

### Phase 10 — Graphics

- user32 / gdi32 (**partial**; see contract matrix)
- GUI dispatch
- **ZirconOSAero** ships **Aero-only** built-in desktop (`src/desktop/aero/`); other themes are out of scope unless reintroduced upstream

### Phase 11 — WOW64 + audio

- WOW64 (PE32, syscall thunking, 32-bit PEB/TEB) — **partial**; modular layout under `src/subsystems/win32/wow64/`
- AC97 / audio — stub or partial; not production-ready

## 3. Next steps

| Area | Notes | Priority |
|------|-------|----------|
| ACPI + PCI | Table walk, ECAM enumeration (QEMU first) | High |
| USB | XHCI HID for keyboard/mouse in QEMU | High |
| Networking | ARP + IPv4 + UDP prototype; TCP later | Medium |
| POSIX subsystem | libc/POSIX mapping | Medium |
| SMP | Multi-core scheduling (APIC/IOAPIC) | Medium |
| Real process isolation | Full user/kernel address separation | High |
| User-mode services | Split Object/I/O/Security servers | High |
| Disk drivers | AHCI/NVMe | Medium |
| Other architectures | aarch64 / riscv64 / loongarch64 CI + QEMU docs; **mips64el** experimental (not Tier-1) | Low |

## 4. Principles

| Principle | Meaning |
|-----------|---------|
| Mechanisms before policy | Kernel mechanisms first; policy in user mode |
| Native before compatibility | Stabilize native API before Win32/POSIX |
| Console before GUI | CLI first, then graphics |
| PE32+ before WOW64 | 64-bit stable, then 32-bit |
| Interfaces first | Clear contracts before code |

## 5. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Weak object model | Breaks API/I/O/security/sync | Design and stabilize objects early |
| Microkernel too small | Everything over IPC — perf/debug pain | Hybrid microkernel + executive |
| GUI/compatibility too early | Stuck in user32/gdi32/WOW64 | Strict phasing |
| Unstable Native API | Weak foundation for Win32 | Solid ntdll first |
| Scope creep | No shippable v1.0 | Clear boundaries and non-goals |

## 6. Deferred surfaces (kernel-first milestone)

The following tracks are **explicitly not** part of the **kernel-usable** milestone; they remain in-tree but must not block MM/SMP/isolation work:

| Track | Notes |
|-------|--------|
| Full GPU DWM / hardware composition | Software compositor + Aero shell only; no claim of Win7 GPU parity |
| Complete Win32 / WOW64 | Expand only after `VMM` + process teardown + CR3 switching are stable |
| NT 32-level priority / boost | See [SCHEDULER_API.md](../cn/SCHEDULER_API.md); current scheduler is an approximation |
