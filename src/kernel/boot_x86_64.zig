// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

// SPDX-License-Identifier: MIT OR Apache-2.0
//! x86_64 multiboot2 bring-up through interactive shell (split from main.zig).

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("../arch.zig");
const klog = @import("../rtl/klog.zig");
const desktop_session = @import("desktop_session.zig");
const mouse = @import("../drivers/input/mouse.zig");
const kbd = @import("../drivers/input/kbd.zig");

extern const stack_top: u8;
extern const _kernel_end: u8;

pub fn start(magic: u32, info_addr: usize) noreturn {
    const boot = arch.impl.boot;
    const paging = arch.impl.paging;
    const frame = @import("../mm/frame.zig");
    const vm = @import("../mm/vm.zig");
    const heap = @import("../mm/heap.zig");
    const heap_boot = @import("../mm/heap_boot.zig");
    const server = @import("../servers/server.zig");
    const smss = @import("../servers/smss.zig");
    const ob = @import("../ob/object.zig");
    const se = @import("../se/token.zig");
    const io = @import("../io/io.zig");
    const scheduler = @import("../ke/scheduler.zig");
    const timer = @import("../ke/timer.zig");
    const port = @import("../lpc/port.zig");
    const vfs_mod = @import("../fs/vfs.zig");
    const fat32_mod = @import("../fs/fat32.zig");
    const ntfs_mod = @import("../fs/ntfs.zig");
    const pe_loader = @import("../loader/pe.zig");
    const elf_loader = @import("../loader/elf.zig");
    const ntdll = @import("../libs/ntdll.zig");
    const kernel32 = @import("../libs/kernel32.zig");
    const console_mod = @import("../subsystems/win32/console.zig");
    const cmd_mod = @import("../subsystems/win32/cmd.zig");
    const subsys = @import("../subsystems/win32/subsystem.zig");
    const exec = @import("../subsystems/win32/exec.zig");
    const user32_mod = @import("../subsystems/win32/user32.zig");
    const gdi32_mod = @import("../subsystems/win32/gdi32.zig");
    const dwmapi_mod = @import("../subsystems/win32/dwmapi.zig");
    const wow64_mod = @import("../subsystems/win32/wow64.zig");
    const sys_config = @import("../config/config.zig");
    const drivers = @import("../drivers/mod.zig");
    const audio = @import("../drivers/audio/audio.zig");
    const registry = @import("../registry/registry.zig");
    const virtio_blk_scratch_fs = @import("../drivers/storage/virtio_blk_scratch_fs.zig");

    // ═══════════════════════════════════════════════════════
    //  Stage A: Early Serial Log  (output: serial only)
    // ═══════════════════════════════════════════════════════
    arch.initSerial();

    klog.info("========================================", .{});
    klog.info("  ZirconOSAero — NT 6.1 hybrid microkernel (Aero desktop)", .{});
    klog.info("  Architecture: x86_64", .{});
    klog.info("========================================", .{});

    if (klog.DEBUG_MODE) {
        klog.info("Build: DEBUG mode (verbose logging enabled)", .{});
    } else {
        klog.info("Build: RELEASE mode (optimized)", .{});
    }

    // ═══ Phase 0: Configuration ═══
    klog.info("--- Phase 0: Loading System Configuration ---", .{});
    sys_config.init();

    klog.info("Config: hostname=%s, version=%s, nt_product_arch=%s host_cpu=%s", .{
        sys_config.getHostname(),
        sys_config.getVersion(),
        sys_config.getNtProductArch(),
        sys_config.hostCpuArchName(),
    });
    klog.info("Config: heap=%uKB, max_procs=%u, tick=%uHz", .{
        sys_config.getHeapSizeKb(),
        sys_config.getMaxProcesses(),
        sys_config.getTickRateHz(),
    });
    klog.info("Config: display=%ux%u@%ubpp, serial=%s", .{
        sys_config.getDefaultWidth(),
        sys_config.getDefaultHeight(),
        sys_config.getDefaultBpp(),
        if (sys_config.isSerialEnabled()) "enabled" else "disabled",
    });
    klog.info("Config: %u total entries loaded", .{sys_config.getTotalConfigEntries()});

    // ═══ Phase 1: Boot Verification + Core Hardware ═══
    klog.info("--- Phase 1: Boot + Early Kernel ---", .{});

    if (magic != boot.MULTIBOOT2_BOOTLOADER_MAGIC) {
        klog.err("Invalid multiboot2 magic: 0x%x (expected 0x%x)", .{
            magic, boot.MULTIBOOT2_BOOTLOADER_MAGIC,
        });
        arch.halt();
    }

    const kernel_stack_addr = @intFromPtr(&stack_top);
    arch.initGdt(kernel_stack_addr);
    klog.info("GDT/TSS initialized (kernel stack=0x%x)", .{kernel_stack_addr});

    const mitigations = @import("../hal/x86_64/mitigations.zig");
    mitigations.enableSmepIfAvailable();
    klog.info("x86_64: SMEP set when CPUID leaf 7 reports support", .{});
    klog.info("x86_64: SMAP available via mitigations.enableSmapIfAvailable() after user-page access audit (stac/clac)", .{});

    const stack_top_addr = @intFromPtr(&stack_top);
    // `stack_top` 在 start.s 的 .bss 前段；大块 Zig BSS（如 FrameAllocator）可在其后。必须用链接脚本
    // `_kernel_end`（与 startGeneric 非 LoongArch 路径一致），否则 PFN 种子会把仍在使用的内核页标为空闲 → Phase3 memset 破坏映像。
    const linker_end_excl = @intFromPtr(&_kernel_end);
    const kernel_end = std.mem.alignForward(usize, linker_end_excl, paging.page_size);
    klog.info("Kernel image end: _kernel_end exclusive=0x%x stack_top=0x%x PFN reserve below 0x%x", .{
        linker_end_excl,
        stack_top_addr,
        kernel_end,
    });
    const boot_info = boot.parse(magic, info_addr);

    // Save framebuffer info for later use; do NOT enable the framebuffer
    // console yet so that all boot log messages go to serial only.
    var has_gfx_fb = false;
    if (boot_info) |info| {
        if (info.fb_info) |fb_i| {
            klog.info("FB tag: addr=0x%x %ux%u pitch=%u bpp=%u type=%u", .{
                @as(usize, @truncate(fb_i.addr)), fb_i.width, fb_i.height, fb_i.pitch, fb_i.bpp, fb_i.fb_type,
            });
            if (fb_i.fb_type != 2 and fb_i.width > 0 and fb_i.height > 0 and fb_i.bpp > 0) {
                has_gfx_fb = true;
            }
        }
    }

    if (boot_info) |info| {
        klog.info("Multiboot2: mem_lower=%u KB, mem_upper=%u KB, mmap_entries=%u", .{
            info.mem_lower_kb,
            info.mem_upper_kb,
            info.mmap_entry_count,
        });
    }

    frame.initGlobalKernelFrames(boot_info, kernel_end);
    {
        const fa = frame.kernelFrameAllocatorPtr();
        if (fa.fb_reserve_end_exclusive > fa.fb_reserve_start) {
            klog.info("Frame: GOP framebuffer excluded from PFN allocator GPA 0x%x-0x%x", .{
                fa.fb_reserve_start,
                fa.fb_reserve_end_exclusive,
            });
        } else if (boot_info) |bi| {
            if (bi.fb_info) |fbi| {
                klog.info("Frame: no linear GOP excluded from PFN (fb_type=%u addr=0x%x); hole punch uses mmap non-RAM only", .{
                    fbi.fb_type,
                    @as(usize, @truncate(fbi.addr)),
                });
            } else {
                klog.info("Frame: no framebuffer tag in boot info; PFN hole punch uses mmap non-RAM only", .{});
            }
        } else {
            klog.info("Frame: no boot info; PFN reserves may be incomplete", .{});
        }
    }
    klog.info("Frame allocator: total_frames=%u, frame_size=%u phys_track_gb=%u (QEMU -m should be ≤ this GiB span)", .{
        frame.kernelFrameAllocatorPtr().total_frames,
        frame.FRAME_SIZE,
        @import("build_options").phys_track_gb,
    });

    // Parse boot mode and desktop theme from multiboot2 command line.
    // When cmdline omits `desktop=`, use compile-time default (Makefile DESKTOP → zig -Ddesktop=).
    const boot_mode: boot.BootMode = if (boot_info) |info| info.boot_mode else .normal;
    var desktop_theme: boot.DesktopTheme = if (boot_info) |info| info.desktop_theme else .none;
    if (desktop_theme == .none) {
        desktop_theme = desktop_session.desktopThemeFromBuildDefault(@import("build_options").default_desktop);
    }
    klog.info("Desktop: effective theme=%s (multiboot cmdline or -Ddefault_desktop)", .{
        desktop_session.desktopThemeName(desktop_theme),
    });

    if (boot_mode == .cmd) {
        klog.info("Boot mode: CMD Shell (direct)", .{});
    } else if (boot_mode == .desktop) {
        klog.info("Boot mode: Desktop (theme=%s)", .{desktop_session.desktopThemeName(desktop_theme)});
    } else {
        klog.info("Boot mode: Normal (default=aero)", .{});
    }

    // ═══ Phase 2: Trap / Timer / Scheduler ═══
    klog.info("--- Phase 2: Trap / Timer / Scheduler ---", .{});

    scheduler.init();
    @import("../ke/apc.zig").init();

    // x86_64 syscall/sysret 前置条件（S1 启动序）：`arch.initGdt` 已设 `TSS.RSP0` 与
    // `gdt.zircon_x86_64_kernel_rsp0`，且 `percpu.syncKernelRsp0` 在 GDT init 内已执行。
    // 须 **早于** `initSyscallInstructionPath`（写 STAR/LSTAR/FMASK 与 KERNEL_GS_BASE）。
    if (@import("build_options").enable_idt) {
        const idt = @import("../arch/x86_64/idt.zig");
        idt.init();
        arch.impl.initSyscallInstructionPath();
        klog.info("IDT initialized (256 vectors; syscall/sysret MSR primary; Debug: vector 128=int 0x80 → same dispatch)", .{});

        timer.init();
        klog.info("Timer: PIC + PIT ready (~100Hz)", .{});

        kbd.init();
        arch.initKeyboard();
        klog.info("Keyboard: PS/2 driver initialized, IRQ1 unmasked", .{});

        mouse.initHardware();
        arch.initMouse();
        klog.info("Mouse: PS/2 driver initialized, IRQ12 unmasked", .{});

        arch.enableInterrupts();
        klog.info("Interrupts enabled", .{});

        mitigations.enableSmapIfAvailable();
        klog.info("x86_64: SMAP enabled when CPU supports (syscall dispatch wraps stac/clac)", .{});
    }

    // ═══ Phase 3: VM + Page Tables ═══
    klog.info("--- Phase 3: VM + Page Tables ---", .{});

    const panic_ctx_vm = @import("../rtl/panic_context.zig");
    panic_ctx_vm.setPhase(0x0003_0005);
    if (builtin.cpu.arch == .x86_64) {
        // 自有 CR3 生效前，`allocFrameCb`→`memsetPhysicalPage` 依赖固件恒等映射；页表帧须取自低 GPA。
        vm.setPagingAllocPhysCeilingExclusive(512 * 1024 * 1024);
    }
    var kernel_space = blk: {
        // Phase 2 可能已开中断；首帧 PML4 的 allocZeroed/memset 与 tick 交错曾导致串口乱流，此处短暂关中断。
        const irq_were_on = arch.saveAndDisableInterrupts();
        defer arch.restoreInterrupts(irq_were_on);
        klog.info("VM: creating kernel address space (PML4)...", .{});
        break :blk vm.createAddressSpace(frame.kernelFrameAllocatorPtr()) orelse {
            panic_ctx_vm.setPhase(0);
            klog.err("Failed to create kernel address space", .{});
            arch.restoreInterrupts(irq_were_on);
            arch.halt();
        };
    };
    panic_ctx_vm.setPhase(0);
    klog.info("VM: kernel address space OK (pml4_phys=0x%x)", .{kernel_space.pml4_phys});

    const kernel_reserve_pages = (kernel_end / paging.page_size) + 4096;
    const min_512mb: usize = 131072; // 512MB / 4KB = 131072 pages
    const pages_per_gib: usize = (1024 * 1024 * 1024) / paging.page_size;
    const track_pages: usize = @as(usize, @intCast(@import("build_options").phys_track_gb)) * pages_per_gib;
    var identity_pages: usize = min_512mb;
    identity_pages = @max(identity_pages, kernel_reserve_pages);
    identity_pages = @max(identity_pages, track_pages);
    const id_bytes: u64 = @as(u64, @intCast(identity_pages)) * @as(u64, @intCast(paging.page_size));
    klog.info("VM: Identity mapping %u pages (%uMB)", .{
        identity_pages, identity_pages * paging.page_size / (1024 * 1024),
    });
    panic_ctx_vm.setPhase(0x0003_0010);
    const id_st = vm.mapIdentityByteRange(&kernel_space, 0, id_bytes, .{ .writable = true, .executable = true }) orelse {
        panic_ctx_vm.setPhase(0);
        klog.err("VM: Identity map failed (mapIdentityByteRange)", .{});
        arch.halt();
    };
    panic_ctx_vm.setPhase(0);
    klog.info("VM: Identity 0-%uMB OK (huge2m=%u leaf=%u)", .{
        identity_pages * paging.page_size / (1024 * 1024),
        id_st.x86_huge_2m,
        id_st.leaf_pages,
    });

    if (builtin.cpu.arch == .x86_64) {
        if (boot_info) |bi| {
            if (bi.acpi_rsdp_phys != 0) {
                const acpi_pci = @import("../hal/x86_64/acpi_pci_early.zig");
                const madt = @import("../hal/x86_64/madt.zig");
                acpi_pci.initFromRsdp(bi.acpi_rsdp_phys);
                madt.initFromRsdp(bi.acpi_rsdp_phys);
                arch.impl.lapic_tick.tryAttachPeriodicFromPhase3();
                const ioapic_rt = @import("../hal/x86_64/ioapic_route.zig");
                ioapic_rt.logIoApicRedirectionMilestone();
            }
        }
    }

    // Map framebuffer region if it lies outside the identity-mapped area
    if (boot_info) |binfo| {
        if (binfo.fb_info) |fb_i| {
            if (fb_i.fb_type != 2) {
                const fb_base = @as(usize, @truncate(fb_i.addr)) & ~@as(usize, paging.page_size - 1);
                const fb_size = @as(usize, fb_i.pitch) * @as(usize, fb_i.height);
                const fb_end = fb_base + fb_size;
                const id_limit = identity_pages * paging.page_size;
                if (fb_base >= id_limit or fb_end > id_limit) {
                    const start_page = if (fb_base >= id_limit) fb_base / paging.page_size else identity_pages;
                    const end_page = (fb_end + paging.page_size - 1) / paging.page_size;
                    const map_lo = start_page * paging.page_size;
                    const map_hi = end_page * paging.page_size;
                    const fb_len = map_hi - map_lo;
                    const fb_flags = vm.MapFlags{ .writable = true, .executable = false, .no_cache = true };
                    _ = vm.mapIdentityByteRange(&kernel_space, map_lo, fb_len, fb_flags) orelse {
                        klog.err("VM: Framebuffer spill map failed 0x%x len 0x%x", .{ map_lo, fb_len });
                        arch.halt();
                    };
                    klog.info("VM: Framebuffer mapped 0x%x-0x%x (%u pages)", .{
                        map_lo, map_hi, end_page - start_page,
                    });
                }
            }
        }
    }

    if (builtin.cpu.arch == .x86_64) {
        vm.setPagingAllocPhysCeilingExclusive(null);
    }
    kernel_space.activate();
    vm.bindKernelAddressSpace(&kernel_space);
    vm.setSectionLazyCommitFillHook(@import("../mm/section.zig").onLazyCommitFillPage);
    klog.info("VM: Kernel page tables loaded", .{});

    if (builtin.cpu.arch == .x86_64) {
        const hpet = @import("../hal/x86_64/hpet.zig");
        const acpi_core = @import("../hal/x86_64/acpi_core.zig");
        const hpet_phys = acpi_core.hpetMmioPhysOrZero();
        if (hpet_phys != 0) hpet.setMmioPhysBase(hpet_phys);
        const hpet_page = hpet.activeMmioPhysBase() & ~@as(u64, 0xFFF);
        if (!vm.mapDeviceMmioIdentity(hpet_page, 4096)) {
            klog.warn("VM: HPET MMIO identity map failed (page 0x%x)", .{@as(u32, @truncate(hpet_page))});
        }
        _ = hpet.initOptional();
        const smp_boot = @import("../hal/x86_64/smp_boot.zig");
        smp_boot.tryStartApplicationProcessorsStub();
    }

    const heap_kb_x86: u64 = @min(sys_config.getHeapSizeKb(), @as(u64, 512 * 1024));
    const heap_kb32: u32 = @truncate(@min(heap_kb_x86, @as(u64, std.math.maxInt(u32))));
    heap_boot.initKernelHeapAfterVm(&kernel_space, heap_kb32);
    klog.info("Kernel heap: growable=%u base=0x%x cap=%uKB committed=%uB live=%uB freelist_nodes=%u", .{
        @intFromBool(heap.isGrowableBacked()),
        heap.kernelHeapBaseVirt(),
        heap.capacityBytes() / 1024,
        heap.totalBytes(),
        heap.usedBytes(),
        heap.freeListDebug().nodes,
    });

    const ex_pool = @import("../mm/ex_pool.zig");
    const irql_early = @import("../ke/irql.zig");
    ex_pool.setPagedPoolIrqlGuard(irql_early.assertBelowDispatchForPagedPool);

    const phys_buddy = @import("../mm/phys_buddy.zig");
    phys_buddy.initKernelContiguousBuddy(frame.kernelFrameAllocatorPtr());
    if (phys_buddy.kernelContiguousBuddyReady()) {
        klog.info("PhysBuddy: contiguous arena leaf_pages=%u (order<=%u)", .{
            phys_buddy.kernelContiguousLeafPages(),
            phys_buddy.kernelContiguousMaxOrder(),
        });
    } else {
        klog.warn("PhysBuddy: no contiguous carve (DMA multi-page may use bitmap scan only)", .{});
    }

    // ═══ Phase 4: Object / Handle / Process Core ═══
    klog.info("--- Phase 4: Object / Handle / Process Core ---", .{});

    ob.init();
    ob.initNamespace();
    @import("../mm/section.zig").registerSectionCleanupHook();
    se.init();
    io.init();

    // ═══ Phase 5: IPC + System Services ═══
    klog.info("--- Phase 5: IPC + System Services ---", .{});

    server.init(frame.kernelFrameAllocatorPtr());

    _ = port.createPort(1, "\\LPC\\PsServer");
    _ = port.createPort(1, "\\LPC\\ObServer");
    _ = port.createPort(1, "\\LPC\\IoServer");
    klog.info("LPC: System service ports created", .{});

    smss.init(frame.kernelFrameAllocatorPtr());

    // ═══ Phase 6: I/O + File System + Driver ═══
    klog.info("--- Phase 6: I/O + File + Driver ---", .{});

    drivers.init();
    drivers.initInputDrivers();
    drivers.initAudioDrivers();

    vfs_mod.init();
    fat32_mod.init();
    ntfs_mod.init();
    if (builtin.target.cpu.arch == .x86_64) {
        drivers.storage.boot_probe.mountBootProbeIfReady();
    }
    virtio_blk_scratch_fs.mountIfVirtioBlkDetected();
    if (builtin.target.cpu.arch == .x86_64) {
        const virtio_blk = drivers.storage.virtio_blk_pci;
        if (virtio_blk.isVirtioBlkPciPresent()) {
            var head: [32]u8 = undefined;
            if (virtio_blk.submitReadSectors(0, &head) == io.STATUS_SUCCESS) {
                klog.info("STORAGE: VirtIO-blk IRP sector0 read OK", .{});
            }
        }
    }

    registry.init();
    @import("../registry/hive.zig").tryLoadBootstrapOverlays();

    klog.info("File Systems: FAT32 (C:\\) + NTFS (D:\\) mounted", .{});
    klog.info("VFS: %u mount points, %u open files", .{
        vfs_mod.getMountCount(), vfs_mod.getFileCount(),
    });

    // ═══ Phase 7: Loader (Enhanced) ═══
    klog.info("--- Phase 7: Loader (PE/ELF Enhanced) ---", .{});

    elf_loader.init();
    pe_loader.init();

    klog.info("Loader: ELF=%u images, PE=%u images (%u DLLs)", .{
        elf_loader.getImageCount(), pe_loader.getImageCount(), pe_loader.getDllCount(),
    });

    // ═══ Phase 8: Native Userland (Enhanced) ═══
    klog.info("--- Phase 8: Native Userland (Enhanced) ---", .{});

    ntdll.init();
    kernel32.init();
    console_mod.init();
    cmd_mod.init();

    // ═══ Phase 9: Win32 Subsystem ═══
    klog.info("--- Phase 9: Win32 Subsystem ---", .{});

    subsys.init();
    exec.init();

    // ═══ Phase 10: Graphical Subsystem ═══
    klog.info("--- Phase 10: Graphical Subsystem ---", .{});

    user32_mod.init();
    gdi32_mod.init();
    dwmapi_mod.ensureLinked();
    subsys.initGuiSubsystem();

    klog.info("GUI: user32 + gdi32 initialized", .{});
    klog.info("GUI: Window classes=%u, GDI stock objects=%u", .{
        user32_mod.getClassCount(), gdi32_mod.getGdiObjectCount(),
    });

    // ═══ Phase 11: WOW64 + Audio ═══
    klog.info("--- Phase 11: WOW64 + Audio ---", .{});

    wow64_mod.init();

    klog.info("WOW64: PE32 support active, thunk table=%u entries", .{
        wow64_mod.getThunkCount(),
    });

    audio.init();

    // ═══════════════════════════════════════════════════════
    //  Stage B: All subsystems ready — now enter display
    // ═══════════════════════════════════════════════════════
    klog.info("--- Phase 12: Display Mode Selection ---", .{});
    klog.info("All kernel subsystems initialized.", .{});

    // Play startup sound event (queued for when audio hardware is available)
    audio.playEvent(.startup);

    // ═══ Desktop / CMD / Text Mode Selection ═══
    if (boot_mode == .desktop or (boot_mode == .normal and has_gfx_fb and desktop_theme != .none)) {
        desktop_session.enterDesktopSession(
            frame.kernelFrameAllocatorPtr(),
            boot_info,
            desktop_theme,
            false,
            true,
            true,
            "desktop",
            "Desktop: isDesktopReady=false (need multiboot framebuffer + initDesktopMode); text mode",
        );
    }

    // Non-desktop mode: now initialize the framebuffer console for text output
    if (has_gfx_fb) {
        if (boot_info) |binfo| {
            if (binfo.fb_info) |fb_i| {
                const fb_addr = @as(usize, @truncate(fb_i.addr));
                arch.initFramebuffer(fb_addr, fb_i.width, fb_i.height, fb_i.pitch, fb_i.bpp);
            }
        }
        arch.consoleClear();
    }

    // ═══ Text Mode Fallback ═══
    klog.info("", .{});
    klog.info("=== ZirconOSAero kernel ready (NT 6.1) ===", .{});
    klog.info("Architecture : %s", .{arch.impl.name});
    klog.info("Processes    : %u", .{@import("../ps/process.zig").getProcessCount()});
    klog.info("Sessions     : %u", .{smss.getSessionCount()});
    klog.info("Heap         : %u/%u bytes used", .{ heap.usedBytes(), heap.totalBytes() });
    klog.info("I/O Devices  : %u, Drivers: %u", .{ io.getDeviceCount(), io.getDriverCount() });
    klog.info("", .{});

    // ═══ Shell Mode Selection ═══
    if (boot_mode == .cmd) {
        klog.info("=== Entering CMD Shell Mode ===", .{});
        cmd_mod.runInteractiveShell();
    }

    // ═══ Normal Text Mode: Demo + Shell ═══
    cmd_mod.runBootSequence();
    exec.runDemoApps();
    gdi32_mod.runGdiDemo();
    user32_mod.runGuiDemo();
    wow64_mod.runWow64Demo();

    klog.info("", .{});
    klog.info("=== Entering Interactive CMD Shell ===", .{});
    klog.info("Type 'help' for available commands.", .{});
    klog.info("", .{});

    cmd_mod.runInteractiveShell();
}
