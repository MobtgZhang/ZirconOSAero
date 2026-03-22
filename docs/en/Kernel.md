# ZirconOS kernel implementation

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
| `syscall_entry.s` | `int 0x80` save/restore |
| `syscall.zig` | Syscall dispatch table |

### Syscall ABI (x86_64)

- Entry: `int 0x80` (vector 128)  
- Number: `rax`  
- Args: `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9`  

Implemented calls:

| # | Name | Role |
|---|------|------|
| 0 | SYS_IPC_SEND | Send IPC message |
| 1 | SYS_IPC_RECEIVE | Receive |
| 2 | SYS_CREATE_PROCESS | Create process |
| 3 | SYS_CREATE_THREAD | Create thread |
| 4 | SYS_MAP_MEMORY | Map memory |
| 5 | SYS_EXIT_PROCESS | Exit process |
| 6 | SYS_CLOSE_HANDLE | Close handle |
| 7 | SYS_GET_PID | Current PID |
| 8 | SYS_YIELD | Yield |
| 9 | SYS_DEBUG_PRINT | Debug print |

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
| unmapPage | Unmap |
| MapFlags | Writable, user, executable, no-cache |

Identity mapping is used; kernel and framebuffer have dedicated mappings.

### 3.3 Kernel heap (`heap.zig`)

- **Algorithm**: Bump allocator  
- **Size**: 512KB  
- **Use**: Kernel dynamic allocation  

## 4. Scheduler (`ke/scheduler.zig`)

| Property | Value |
|----------|-------|
| Algorithm | Round-robin |
| Max threads | 32 |
| Stack size | 8KB |
| Tick | PIT IRQ0 |
| States | ready, running, blocked, terminated |
| Control | `scheduling_enabled` can pause scheduling |

## 5. Interrupts and timer

### IDT (`idt.zig`)

- 0–31: CPU exceptions  
- 32–47: Hardware IRQs  
- 128: syscall (`int 0x80`)  

### PIC + PIT

| Part | Role |
|------|------|
| PIC | 8259A cascaded |
| PIT | ~100 Hz tick |

### Dispatch chain

```
HW interrupt / exception / int 0x80
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

IRP-based I/O.

### Objects

| Object | Role |
|--------|------|
| DriverObject | Driver entry + dispatch table |
| DeviceObject | Device on a stack |
| Irp | One I/O operation |

### Major functions

create, close, read, write, ioctl, query_info, …

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

## 8. Filesystems (`fs/`)

### VFS (`vfs.zig`)

| Concept | Role |
|---------|------|
| MountPoint | Mount tracking |
| FileObject | Open file |
| FsOps | FS operations |

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
