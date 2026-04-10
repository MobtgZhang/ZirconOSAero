# NT 6.1 Public Documentation Contract Matrix (ZirconOSAero)

> **Status labels** are defined in the table below. **Authority**: [DOCS_INDEX.md](../DOCS_INDEX.md) §STATUS_LEGEND. **Verification**: must align with `zig build test`, CI, [MVT_NT61.md](MVT_NT61.md), and [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md). Do not mark items "done" in this matrix without adding automated tests.

## Status Label Legend

| Label | Meaning |
|-------|---------|
| **Done** | Main path demonstrable under QEMU/CI smoke; aligns with this row's description. Does **not** imply retail Windows 7 kernel parity. |
| **Partial** | Subset implemented; known gaps vs. documentation in the "Status" column. |
| **Stub** | Symbol/struct exists; execution path not implemented or placeholder only. |
| **Planned** | Designed or on roadmap; code not landed. |
| **Verified** | Has host unit test or CI step for automated regression (see [MVT_NT61.md](MVT_NT61.md)). |

## Scope and Clean-Room Boundary

Commercial Windows **Win32 / csrss / WOW64 / ntdll** cover hundreds of Native and Win32 entry points; **GDI** (BitBlt ROP, font rasterization, device contexts) and **csrss** (window stations, desktops, sessions, LPC protocol) are multi-year engineering efforts.

This repository aims to deliver, under clean-room constraints (Microsoft Learn, WDK, hardware specs, published ABI tables only), a **subset** aligned with NT 6.1 public documentation and verifiable by [MVT_NT61.md](MVT_NT61.md) / `tests/`. Phase 4 strengthens **ABI anchors** for the implemented subset: `dwm_nt61_abi_inventory.zig` (dwmapi export table), `nt61_core_dll_abi_inventory.zig` (ntdll/kernel32/user32 export ordering), `dwmapi_wow64.zig` (PE32 layout), and host tests.

Does **not** claim:
- Full binary compatibility with Windows 7 user-mode DLLs in any environment
- Complete Win32, complete SysWOW64, or complete csrss semantics (see [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md))

Public statements must source from [API_COMPAT_MATRIX.md](../cn/API_COMPAT_MATRIX.md) and [Subsystems.md](Subsystems.md).

---

## 0. Kernel Memory, Virtual Memory, and SMP (Baseline)

| Capability | Module | Status |
|-----------|--------|--------|
| Physical frame bitmap + mmap filtering | `src/mm/frame.zig` | Partial — see [PHYS_ALLOC_AUDIT.md](../cn/PHYS_ALLOC_AUDIT.md) |
| Buddy + contiguous physical pages封装 | `buddy.zig` / `phys_buddy.zig` | Partial — `main.zig` startup `initKernelContiguousBuddy` |
| General heap + stats / `heap_check` | `src/mm/heap.zig` | Partial |
| Ex pool path + IRQL + allocation overview | `src/mm/ex_pool.zig` | Partial — **Verified** (host `pool`) |
| Slab cache | `src/mm/slab.zig` | Partial |
| VMA slots + `mmFreeVirtualRange` | `src/mm/vm.zig` | Partial |
| fork subset: user 4Ki/16Ki leaf dup + CoW; large pages (x86 2MiB / LoongArch 32MiB) split into small leaves | `vm.zig` / `paging.zig` / `frame.zig` | Partial — host **fork_cow_share_nt61_host** (**Verified**); **K1.4 Verified** |
| User pointer probing | `src/mm/probe.zig` | Partial — syscall paths covered |
| Process page table release (user half) | `arch/x86_64/paging.zig` `releaseUserHalfAddressSpace` | Partial |
| CR3 switch on scheduling | `src/ke/scheduler.zig` | Partial — tick path `activateCr3ForProcessId` |
| LoongArch64 ASID management | `hal/loongarch64/tlb_flush.zig` / `ke/kpcr.zig` | Partial — **K1.8 Verified** |
| ACPI MADT / LAPIC / first IOAPIC base enumeration | `src/hal/x86_64/madt.zig` | Partial |
| AP entry / TLB IPI / LAPIC tick | `ap_entry.zig` / `tlb_broadcast.zig` / `smp_boot.zig` / `lapic_smp.zig` | Partial |
| Per-CPU scheduling and stealing | `percpu_sched.zig` / `scheduler.zig` | Partial |
| Monotonic clock / HPET read-only | `ke/timekeeping.zig` / `hal/x86_64/hpet.zig` | Partial — HPET MMIO probe; IRQ0 still PIT |
| Kernel #PF structured STOP | `src/ke/bugcheck.zig` | Partial |
| Section object last-reference teardown | `src/mm/section.zig` | Partial |

---

## 1. Kernel / HAL: Interrupt, Timer, DPC, IRQL

| Capability | Module | Status |
|-----------|--------|--------|
| IDT (256 vectors) | `idt.zig` | Partial |
| PIC + PIT (~100 Hz tick) | `pic.zig`, `pit.zig` | Partial |
| HPET monotonic counter (read-only) | `hpet.zig` | Partial — not wired to IRQ0 |
| IRQL model (PASSIVE/APC/DISPATCH subset) | `ke/irql.zig` | Partial — no full DIRQL device stack |
| DPC per-CPU FIFO | `ke/dpc.zig` | Partial |
| LAPIC timer (optional periodic tick) | `lapic_timer_tick.zig` | Partial |

---

## 2. Scheduler (32-Level FIFO Buckets)

| Capability | Module | Status |
|-----------|--------|--------|
| Preemptive multi-priority ready queues | `ke/scheduler.zig` | Partial — 32-level FIFO buckets |
| Tick (~100 Hz PIT IRQ0) | `scheduler.zig` | Partial |
| Thread states (ready/running/blocked/terminated) | `scheduler.zig` | Partial |
| Mutex priority inheritance (depth model) | `sync.zig` | Partial — host **mutex_inherit_depth_host** |
| IRQL / DPC interaction | `ke/dpc.zig`, `interrupt_x86.zig` | Partial |
| Kernel/User APC queues | `ke/apc.zig`, `ke/apc_object.zig` | Partial — **K2.9 Verified** |

---

## 3. Object Manager, Security, LPC

| Capability | Module | Status |
|-----------|--------|--------|
| Object header / type / ref count / handle count | `ob/object.zig` | Partial |
| Handle table per-process | `ob/handle.zig` | Partial |
| Namespace tree + symlinks | `ob/object.zig` | Partial |
| Security token / DAC / ACL | `se/token.zig` | Partial — host **se_token** (**Verified**) |
| LPC ports (request/reply) | `lpc/port.zig` | Partial — **Verified** (host tests) |
| `handshake_version` v2 anchors | `lpc/port.zig` | Partial — **lpc_handshake_version_host** (**Verified**) |
| ALPC placeholder | `lpc/alpc_min.zig` | Stub |
| csrss skeleton | `servers/csrss_skeleton.zig` | Stub |

---

## 4. I/O Manager and Drivers

| Capability | Module | Status |
|-----------|--------|--------|
| IRP-based I/O | `io/io.zig` | Partial — **Verified** (`io_irp_host`) |
| Driver dispatch | `io/io.zig` | Partial |
| Device stack (VirtIO-BLK PCI) | `virtio_blk_pci.zig` | Partial — smoke test |
| VFS bridge | `vfs.zig` | Partial |
| FAT32 (`C:\`) | `fs/fat32.zig` | Partial |
| NTFS (`D:\`) subset | `fs/ntfs.zig` | Partial — MFT basics |
| AHCI / NVMe | `ahci.zig` / `nvme.zig` | Partial — see [STORAGE_IO_ROADMAP.md](../cn/STORAGE_IO_ROADMAP.md) |
| USB XHCI (QEMU) | `usb/xhci.zig` | Partial — see [HAL_USB_NET_ROADMAP.md](../cn/HAL_USB_NET_ROADMAP.md) |

---

## 5. PE Loader, PEB/TEB, Loaders

| Capability | Module | Status |
|-----------|--------|--------|
| PE32+ loader | `loader/pe.zig` | Partial |
| PE32 loader (WOW64) | `loader/pe.zig` | Partial |
| Import resolution | `loader/pe.zig` | Partial |
| Relocations | `loader/pe.zig` | Partial |
| PEB/TEB x64 layout | `src/sdk/teb_nt61_x64.zig` | Partial — **nt61_abi_layout_host** (**Verified**) |
| ELF64 loader | `loader/elf.zig` | Partial |
| Section objects | `mm/section.zig` | Partial |

---

## 6. Win32 Subsystem (user32 / gdi32 / kernel32)

| Capability | Module | Status |
|-----------|--------|--------|
| ntdll (Native API subset) | `src/libs/ntdll.zig` | Partial — **Verified** (ssdt stubs) |
| kernel32 base subset | `src/libs/kernel32.zig` | Partial |
| user32 window/message subset | `subsystems/win32/user32.zig` | Partial — see [Subsystems.md](Subsystems.md) |
| gdi32 subset (BitBlt/ROP) | `subsystems/win32/gdi32.zig` | Partial |
| WOW64 thunk + dual SSDT | `subsystems/win32/wow64/` | Partial — **wow64_ssdt_x86** (**Verified**) |
| CMD (in-kernel) | `src/shell/cmd.zig` | Partial |
| Win32k architecture | `subsystems/win32k/mod.zig` | Partial — stub |

---

## 7. Display, DWM, Aero, Graphics

| Capability | Module | Status |
|-----------|--------|--------|
| Framebuffer (linear, VGA text) | `drivers/video/core/framebuffer.zig` | Partial |
| Display manager (IOCTL_DISPLAY_SET_MODE) | `drivers/video/core/display.zig` | Partial — **Verified** (host layout test) |
| DWM compositor | `drivers/video/core/dwm.zig` | Partial |
| Aero glass / blur / composition | `desktop/aero/` | Partial |
| VirtIO-GPU 2D scanout | `drivers/video/virtio/virtio_gpu_pci.zig` | Partial — **VirtIO-GPU: GET_DISPLAY_INFO + RESOURCE_CREATE_2D + TRANSFER_* scratch loop** smoke |
| VirtIO-GPU VirGL (Phase4-Plus) | `drivers/video/virtio/` | Partial — `CMD_SUBMIT_3D` stub |
| Colorref ↔ Kernel BGR conversion | `config/color_nt61.zig` | Partial — **color_nt61_host** (**Verified**) |
| Aero flag mapping (kernel ↔ userspace) | `config/aero_flag_mapping.zig` | Partial — **aero_flag_mapping_host** (**Verified**) |
| WM_DWM* message constants | `config/dwm_nt61_api_contract.zig` | Partial — **dwm_messages_nt61_host** (**Verified**) |
| DWM notification broadcast | `dwm.zig` / `user32.zig` | Partial |

---

## 8. Cross-cutting and Deferred Surfaces

### Explicitly Deferred (Do Not Block MM/SMP/Isolation)

| Track | Status |
|-------|--------|
| Full GPU DWM / hardware composition | Deferred — software compositor + Aero shell only |
| Complete Win32 / WOW64 | Deferred — expand only after VMM + process teardown + CR3 switching stable |
| NT 32-level priority / boost | Deferred — current scheduler is an approximation |
| Full TCP / production networking stack | Deferred |
| ACPI AML interpreter | Deferred |
| ACPI S1–S4 deep sleep | Deferred |
| Complete ARM64EC / CHPE | Out of scope |

See [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) for full list.

---

## Related Links

| Document | Purpose |
|----------|---------|
| [MVT_NT61.md](MVT_NT61.md) | Reproducible verification steps |
| [NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md) | Kernel K0–K8 backlog |
| [Subsystems.md](Subsystems.md) | Subsystem overview |
| [Roadmap.md](Roadmap.md) | Phase 0–11 milestone roadmap |
| [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) | CI toolchain alignment |
