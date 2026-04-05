# ZirconOSAero kernel implementation (NT 6.1 target)

This document describes the main kernel subsystems.

## 1. Source layout

```
src/
├── main.zig           # Entry, Phase 0–12 init
├── arch.zig           # Arch dispatch
├── arch/
│   ├── x86_64/        #   start.s, boot.zig, paging.zig, idt.zig, syscall.zig, ...
│   ├── aarch64/
│   ├── loongarch64/
│   ├── riscv64/
│   └── mips64el/
├── hal/
│   ├── x86_64/        #   vga, pic, pit, serial, gdt, ...
│   └── aarch64/       #   gic, timer, pl011
├── ke/                # Kernel Executive
│   ├── scheduler.zig
│   ├── timekeeping.zig
│   ├── timer.zig
│   ├── interrupt.zig  # IRQ + syscall entry
│   └── sync.zig
├── mm/
│   ├── frame.zig
│   ├── vm.zig
│   └── heap.zig
├── ob/
│   └── object.zig
├── ps/
├── se/
│   └── token.zig
├── io/
│   └── io.zig
├── lpc/
│   ├── port.zig
│   └── ipc.zig
├── fs/
│   ├── vfs.zig
│   ├── fat32.zig      # C:\
│   └── ntfs.zig       # D:\
├── loader/
│   ├── pe.zig
│   └── elf.zig
├── drivers/
│   ├── video/         # VGA, HDMI, framebuffer, display, DWM
│   ├── audio/         # AC97
│   └── input/         # PS/2 mouse
├── rtl/
├── config/
└── registry/
```

### 1.1 NT 6.1 alignment (Chinese docs)

- [docs/cn/PROCESS_NT61.md](../cn/PROCESS_NT61.md) — phased delivery  
- [docs/cn/NT61_CONTRACT_MATRIX.md](../cn/NT61_CONTRACT_MATRIX.md) — API / WDK index  
- [docs/cn/SyscallABI.md](../cn/SyscallABI.md) — `syscall`/`sysret` + Windows SSDT 子集  

## 2. Architecture support (`arch/`)

Selected via `src/arch.zig` for the build target.

### x86_64 (primary)

| File | Role |
|------|------|
| `start.s` | 32-bit entry → page tables → PAE + long mode + paging → 64-bit → stack/SSE → `kernel_main` |
| `boot.zig` | Multiboot2: mmap, command line, framebuffer, boot mode and theme |
| `paging.zig` | Four-level tables, identity map, framebuffer map |
| `idt.zig` | 256 IDT vectors |
| `isr_common.s` | Exception + IRQ stubs → `isr_common_handler` |
| `syscall_lstar.s` | `syscall`/`sysret` entry (IA32_LSTAR) |
| `syscall.zig` | Syscall dispatch table |

### Syscall ABI (x86_64)

- Entry: **`syscall`/`sysret` only** (vector 128 is default stub; unsupported CPU → bugcheck; see [SyscallABI.md](../cn/SyscallABI.md))  
- Number: `rax` = public **Windows 7 SP1 x64** SSDT index (subset)  
- Args: **NT x64** — 1st in `r10`, then `rdx`/`r8`/`r9`, rest on user stack ([SyscallABI.md](../cn/SyscallABI.md))  

Authoritative indices and handlers: [`ssdt_nt61.zig`](../../src/arch/x86_64/ssdt_nt61.zig), [`syscall.zig`](../../src/arch/x86_64/syscall.zig). There is no `0x0010_0000` internal service namespace.

## 3. Memory management (`mm/`)

### 3.1 Frame allocator (`frame.zig`)

- **Algorithm**: Bitmap of physical pages  
- **Source**: Multiboot2 memory map  
- **Capacity**: ~1GB physical  
- **Page size**: 4KB  

### 3.2 Virtual memory (`vm.zig`)

| API | Role |
|-----|------|
| AddressSpace | Per-process address space |
| mapPage | Map virtual to physical |
| mapIdentityByteRange | Fast boot-time identity: x86_64 uses 2 MiB pages (PDE.PS, Intel SDM Vol.3); LoongArch64 fills 32 MiB L2 tables (2048×16 KiB); tail uses leaf `mapPage` |
| unmapPage | Unmap |
| MapFlags | Writable, user, executable, no-cache |

Identity mapping is used; kernel and framebuffer have dedicated mappings. Startup logs may report `huge2m` / `leaf` (x86) or `la32m` / `leaf` (LoongArch) counts.

### 3.3 Kernel heap (`heap.zig`)

- **Algorithm**: Bump high-water plus per-block metadata and a **free list** with **address-ordered insert and coalescing** of adjacent free blocks (textbook segregated free-list heap; not a Windows pool clone).  
- **Size**: On freestanding builds, the arena is **VM-backed** (grows by mapping pages up to `memory.heap_size_kb` in config) with a static fallback if VM init fails; host unit tests use a fixed 512KB static buffer.  
- **Use**: Backing store for `mm/pool` and general kernel dynamic allocation; see [MM_HEAP_POOL_SLAB.md](../cn/MM_HEAP_POOL_SLAB.md) (Chinese) for the full picture.  

## 4. Scheduler (`ke/scheduler.zig`)

Chinese detail: [docs/cn/SCHEDULER_API.md](../cn/SCHEDULER_API.md).

| Property | Value |
|----------|-------|
| Algorithm | Per-logical-CPU 32-level FIFO ready buckets + priority-class quanta + starvation / I/O boost hooks |
| Max threads | Build-time `-Dmax_scheduler_threads=` (clamped 8..256, default 64) |
| Stack size | 8KB |
| Tick | PIT IRQ0 (~100Hz) drives `scheduler.tick` |
| States | ready, running, blocked, terminated |
| Control | `scheduling_enabled` can pause scheduling |
| Process teardown | `ps/process.zig` calls `before_release_process_address_space` so no thread keeps a released user CR3 (K2.1) |

## 5. Interrupts and timer

### IDT (`idt.zig`)

- 0–31: CPU exceptions  
- 32–47: Hardware IRQs  
- 128: default stub (not syscall)  

### PIC + PIT

| Part | Role |
|------|------|
| PIC | 8259A cascaded |
| PIT | ~100 Hz tick |

### Timekeeping (`ke/timekeeping.zig`) and HPET (x86_64)

- **`readInterruptTicks`**: same counter as the preemptive scheduler (`scheduler.getTicks`).  
- **`readMonotonicRaw`**: HPET main counter when `hal/x86_64/hpet.zig` probe succeeds after MMIO identity-map; otherwise falls back to interrupt ticks. IRQ0 is **not** switched to HPET yet — see [TimerPrecisionRoadmap.md](../cn/TimerPrecisionRoadmap.md).  
- LAPIC one-shot / single tick source migration: stub log in `hal/x86_64/lapic_timer_tick.zig`.

### Dispatch chain

```
HW interrupt / exception / syscall path (MSR, not IDT 128)
    → IDT vector
    → ISR stub (isr_common.s)
    → isr_common_handler
    → interrupt.zig
    → exception / IRQ / syscall handling
```

## 6. Object Manager (`ob/object.zig`)

NT-style unified object management.

### Structures

- **ObjectHeader**: type, ref count, handle count, name  
- **HandleTable**: per-process handles → (object, rights, flags)  
- **Namespace**: tree with directories and symlinks  
- **Waitable**: waitable object interface  

### Operations

| Op | Role |
|----|------|
| Create | Allocate header + type body |
| Reference | Adjust ref count |
| Name | Register in namespace |
| Handle | Insert into handle table |
| Wait | Wait for signal |
| Close | Decrement handles; destroy if zero |

## 7. I/O Manager (`io/io.zig`)

IRP-based I/O. `Irp.status` and driver dispatch return values use **`NTSTATUS`** (`io.NTSTATUS`), aligned with the same numeric subset as [`ntdll`](../../src/libs/ntdll.zig).

### Objects

| Object | Role |
|--------|------|
| DriverObject | Per–major-function `major_dispatch[]` plus legacy single `dispatch` fallback |
| DeviceObject | Device on a stack; fixed `DeviceExtension` blob; `IoGetDeviceExtension` |
| Irp | One I/O operation; `system_buffer` / `user_buffer` / `mdl_address` / `io_status_block_ptr` (WDK-shaped subset); `tail` tunnel (e.g. `FileObject*`) |

### Major functions

create, close, read, write, ioctl, query_info, pnp, power, …

### Device kinds

console, serial, keyboard, disk, framebuffer, mouse, audio, …

### Path

```
User API
  → I/O Manager
  → build IRP
  → device stack
  → driver dispatch
  → complete IRP
```

### Async / cancel (subset)

- `IoMarkIrpPending`, `IoCancelIrp`, and a two-slot LIFO completion stack (`IoSetCompletionRoutine` / `IoCompleteRequest`).
- DPC drain hook contract: see [`ke/dpc.zig`](../../src/ke/dpc.zig) (K4.4).

### Block IRP smoke (VirtIO-BLK PCI)

When PCI enumeration sees `1af4:1042`, [`virtio_blk_pci`](../../src/drivers/storage/virtio_blk_pci.zig) registers a stub disk and `submitReadSectors` issues `IRP_MJ_READ`. Kernel log line `STORAGE: VirtIO-blk IRP sector0 read OK` after a successful boot-path read.

### VFS bridge

Native file read/write/close go through [`vfs.dispatchFileObjectIrp`](../../src/fs/vfs.zig): if the mount has a **volume device object**, the IRP is sent with `dispatchIrpThroughStack`; otherwise the path falls back to direct `FsOps`. [`ntdll`](../../src/libs/ntdll.zig) builds minimal `Irp` values and maps completed `NTSTATUS` into `IO_STATUS_BLOCK`.

### Reproduce (host)

```bash
zig build test   # includes io_irp_host, fs_status_nt_map_host
```

## 8. Filesystems (`fs/`)

### VFS (`vfs.zig`)

| Concept | Role |
|---------|------|
| MountPoint | Mount tracking + optional `volume_device_idx` (stack top for IRP) |
| FileObject | Open file; `share_access`; `dir_enum_next` for `NtQueryDirectoryFile` |
| FsOps | FS operations |

`NtCreateFile` / `NtOpenFile` use `resolvePath` (object-path normalization), `share_access`, and a subset of `create_disposition` / `create_options`. `NtQueryDirectoryFile` returns one `FILE_NAMES_INFORMATION` entry per call for directory handles.

### FAT32 (`fat32.zig`)

- Mount `C:\`  
- Create/read/write/directories/delete  

### NTFS (`ntfs.zig`)

- Mount `D:\`  
- MFT-based file and directory ops  

## 9. Loaders (`loader/`)

### PE (`pe.zig`)

| Feature | Role |
|---------|------|
| PE32+ | 64-bit PE |
| PE32 | 32-bit PE (WOW64) |
| DLLs | Import resolution |
| Relocations | Base reloc |
| PEB/TEB | Process/thread environment |

### ELF (`elf.zig`)

- Multi-arch ELF  
- ELF64 headers and segments  
- Shared objects  

## 10. Drivers (`drivers/`)

### Video (`drivers/video/`)

| Module | Role |
|--------|------|
| vga.zig | VGA text |
| hdmi.zig | HDMI |
| framebuffer.zig | Linear framebuffer |
| display.zig | Desktop/display manager, Windows-style themes |
| dwm.zig | Desktop Window Manager compositor |

Themes: Classic, Luna, Aero, Modern, Fluent, Sun Valley.

**Desktop mouse and compositing (`main.zig` + `display.zig`)**

- IRQ12 updates absolute coordinates in `mouse.zig` and sets `cursor_moved`; events are queued for buttons/wheel.  
- The main loop must call `renderDesktopFrame()` when **`hasCursorMoved()`** is true even if no event was popped: otherwise queue overflow can update coordinates without a redraw.  
- `renderDesktopFrame()` drains **all** PS/2 substeps for `isInterpolating()` in one frame so interpolation does not rely on multiple timer wakeups.  

### Audio (`drivers/audio/`)

| Module | Role |
|--------|------|
| ac97.zig | AC97 controller |
| audio.zig | Audio events (e.g. startup sound) |

### Input (`drivers/input/`)

| Module | Role |
|--------|------|
| mouse.zig | PS/2 mouse (x86_64) |

## 11. Synchronization (`ke/sync.zig`)

| Primitive | Role |
|-----------|------|
| SpinLock | Spinlock |
| Event | Manual/auto-reset events |
| Mutex | Mutex |
| Semaphore | Counting semaphore |

## 12. Registry (`registry/`)

Lightweight Windows-style registry (key/value storage).
