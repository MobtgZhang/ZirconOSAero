# ZirconOS roadmap

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
- Dual shell (CMD + PowerShell)

## 2. Milestones (Phase 0–11)

### Phase 0 — Tooling ✅

- Zig cross-compilation
- QEMU debugging
- Serial logging
- Build system (`build.zig` / Makefile / `run.sh`)

### Phase 1 — Boot + early kernel ✅

- GRUB Multiboot2
- UEFI boot application
- GDT/TSS
- Physical memory discovery + frame allocator
- Kernel heap (bump allocator)
- VGA text + serial

### Phase 2 — Interrupts / timer / scheduler ✅

- IDT (256 vectors)
- PIC + PIT (~100 Hz)
- Round-robin scheduler
- Keyboard/mouse drivers
- Sync primitives (spinlock, event, mutex, semaphore)

### Phase 3 — Virtual memory ✅

- Four-level page tables
- Identity mapping
- Framebuffer mapping
- User/kernel separation
- Page table switches

### Phase 4 — Objects / handles / process core ✅

- Object Manager (headers, types, namespace)
- Per-process handle tables
- Process/thread objects
- Security tokens
- Waitable objects

### Phase 5 — IPC + services ✅

- LPC ports
- Synchronous request/reply
- Process Server (PID 1)
- Session Manager / SMSS (PID 2)
- System LPC port registration

### Phase 6 — I/O + filesystem + drivers ✅

- I/O Manager (driver/device/IRP)
- VFS
- FAT32 (`C:\`)
- NTFS (`D:\`)
- Registry
- Video/audio/input drivers

### Phase 7 — Loaders ✅

- ELF64 loader
- PE32+ loader
- PE32 loader
- DLL loading and import resolution
- Base relocations

### Phase 8 — Userland foundation ✅

- ntdll (Native API)
- kernel32 (Win32 base)
- Console runtime
- CMD
- PowerShell

### Phase 9 — Win32 subsystem ✅

- csrss server
- Win32 execution engine
- PE load + DLL binding
- Process lifecycle

### Phase 10 — Graphics ✅

- user32 (windows, messages, classes, input)
- gdi32 (DC, drawing, fonts, bitmaps)
- GUI dispatch
- Desktop theme scaffolding (Classic/Luna/Aero/Modern/Fluent/Sun Valley)

### Phase 11 — WOW64 + audio ✅

- WOW64 (PE32, syscall thunking, 32-bit PEB/TEB)
- AC97 audio driver
- Audio event path

## 3. Next steps

| Area | Notes | Priority |
|------|-------|----------|
| POSIX subsystem | libc/POSIX mapping | Medium |
| SMP | Multi-core scheduling (APIC/IOAPIC) | Medium |
| Networking | TCP/IP, sockets | Medium |
| Real process isolation | Full user/kernel address separation | High |
| User-mode services | Split Object/I/O/Security servers | High |
| Disk drivers | AHCI/NVMe | Medium |
| ACPI | Power management | Low |
| Other architectures | aarch64/riscv64 polish | Low |

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
