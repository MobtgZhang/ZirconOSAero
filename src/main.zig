const builtin = @import("builtin");
const arch = @import("arch.zig");
const klog = @import("rtl/klog.zig");
const std = @import("std");

pub const panic = std.debug.FullPanic(panicImpl);

fn writeHexU32ToConsole(n: u32) void {
    var buf: [8]u8 = undefined;
    var x = n;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        const d: u4 = @truncate(x & 15);
        const du = @as(u8, d);
        buf[i] = if (d < 10) '0' + du else 'a' + (du - 10);
        x >>= 4;
    }
    arch.consoleWrite(buf[0..]);
}

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    arch.consoleWrite("KERNEL PANIC: ");
    arch.consoleWrite(msg);
    const phase = @import("rtl/panic_context.zig").getPhase();
    if (builtin.mode == .Debug and phase != 0) {
        arch.consoleWrite(" [phase=0x");
        writeHexU32ToConsole(phase);
        arch.consoleWrite("]");
    }
    arch.consoleWrite("\n");
    arch.halt();
}

extern const stack_top: u8;
extern const _kernel_end: u8;

comptime {
    switch (builtin.target.cpu.arch) {
        .aarch64 => _ = @import("arch/aarch64/mod.zig"),
        .loongarch64 => _ = @import("arch/loongarch64/mod.zig"),
        .riscv64 => _ = @import("arch/riscv64/mod.zig"),
        .mips64el => _ = @import("arch/mips64el/mod.zig"),
        else => {},
    }
    _ = @import("mm/pool.zig");
    _ = @import("mm/section.zig");
    _ = @import("ke/apc.zig");
    _ = @import("ke/roadmap_hooks.zig");
    _ = @import("mm/slab.zig");
    _ = @import("mm/phys_buddy.zig");
    _ = @import("mm/heap_boot.zig");
    _ = @import("mm/ex_pool.zig");
    _ = @import("mm/probe.zig");
    _ = @import("ke/spinlock.zig");
    _ = @import("ke/percpu_sched.zig");
    if (builtin.cpu.arch == .x86_64) {
        _ = @import("hal/x86_64/ap_entry.zig");
        _ = @import("hal/x86_64/tlb_broadcast.zig");
    }
}

/// UEFI/汇编以 64 位寄存器传参；首参截断为 u32 供 Multiboot2 magic 比对（与 LoongArch handoff 习惯一致）。
pub export fn kernel_main(magic_arg: usize, info_addr: usize) callconv(.c) noreturn {
    const magic = @as(u32, @truncate(magic_arg));
    switch (builtin.target.cpu.arch) {
        .x86_64 => startX86_64(magic, info_addr),
        else => startGeneric(magic, info_addr),
    }
}

fn startX86_64(magic: u32, info_addr: usize) noreturn {
    const boot = arch.impl.boot;
    const paging = arch.impl.paging;
    const frame = @import("mm/frame.zig");
    const vm = @import("mm/vm.zig");
    const heap = @import("mm/heap.zig");
    const heap_boot = @import("mm/heap_boot.zig");
    const server = @import("servers/server.zig");
    const smss = @import("servers/smss.zig");
    const ob = @import("ob/object.zig");
    const se = @import("se/token.zig");
    const io = @import("io/io.zig");
    const scheduler = @import("ke/scheduler.zig");
    const timer = @import("ke/timer.zig");
    const port = @import("lpc/port.zig");
    const vfs_mod = @import("fs/vfs.zig");
    const fat32_mod = @import("fs/fat32.zig");
    const ntfs_mod = @import("fs/ntfs.zig");
    const pe_loader = @import("loader/pe.zig");
    const elf_loader = @import("loader/elf.zig");
    const ntdll = @import("libs/ntdll.zig");
    const kernel32 = @import("libs/kernel32.zig");
    const console_mod = @import("subsystems/win32/console.zig");
    const cmd_mod = @import("subsystems/win32/cmd.zig");
    const subsys = @import("subsystems/win32/subsystem.zig");
    const exec = @import("subsystems/win32/exec.zig");
    const user32_mod = @import("subsystems/win32/user32.zig");
    const gdi32_mod = @import("subsystems/win32/gdi32.zig");
    const wow64_mod = @import("subsystems/win32/wow64.zig");
    const sys_config = @import("config/config.zig");
    const drivers = @import("drivers/mod.zig");
    const audio = @import("drivers/audio/audio.zig");
    const registry = @import("registry/registry.zig");
    const virtio_blk_scratch_fs = @import("drivers/storage/virtio_blk_scratch_fs.zig");

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

    const mitigations = @import("hal/x86_64/mitigations.zig");
    mitigations.enableSmepIfAvailable();
    klog.info("x86_64: SMEP set when CPUID leaf 7 reports support", .{});
    klog.info("x86_64: SMAP available via mitigations.enableSmapIfAvailable() after user-page access audit (stac/clac)", .{});

    const stack_top_addr = @intFromPtr(&stack_top);
    const kernel_end = ((stack_top_addr + (4 * 1024 * 1024) - 1) / (4 * 1024 * 1024)) * (4 * 1024 * 1024);
    klog.info("Kernel end estimated: 0x%x (stack_top=0x%x)", .{ kernel_end, stack_top_addr });
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

    var alloc: frame.FrameAllocator = undefined;
    alloc.init(boot_info, kernel_end);
    frame.setKernelFrameAllocator(&alloc);
    klog.info("Frame allocator: total_frames=%u, frame_size=%u", .{
        alloc.total_frames, frame.FRAME_SIZE,
    });

    // Parse boot mode and desktop theme from multiboot2 command line.
    // When cmdline omits `desktop=`, use compile-time default (Makefile DESKTOP → zig -Ddesktop=).
    const boot_mode: boot.BootMode = if (boot_info) |info| info.boot_mode else .normal;
    var desktop_theme: boot.DesktopTheme = if (boot_info) |info| info.desktop_theme else .none;
    if (desktop_theme == .none) {
        desktop_theme = desktopThemeFromBuildDefault(@import("build_options").default_desktop);
    }
    klog.info("Desktop: effective theme=%s (multiboot cmdline or -Ddefault_desktop)", .{
        desktopThemeName(desktop_theme),
    });

    if (boot_mode == .cmd) {
        klog.info("Boot mode: CMD Shell (direct)", .{});
    } else if (boot_mode == .desktop) {
        klog.info("Boot mode: Desktop (theme=%s)", .{desktopThemeName(desktop_theme)});
    } else {
        klog.info("Boot mode: Normal (default=aero)", .{});
    }

    // ═══ Phase 2: Trap / Timer / Scheduler ═══
    klog.info("--- Phase 2: Trap / Timer / Scheduler ---", .{});

    scheduler.init();

    if (@import("build_options").enable_idt) {
        const idt = @import("arch/x86_64/idt.zig");
        idt.init();
        const syscall_msr = @import("arch/x86_64/syscall_msr.zig");
        syscall_msr.initSyscallInstructionPath();
        klog.info("IDT initialized (256 vectors, vector 128 = syscall)", .{});

        timer.init();
        klog.info("Timer: PIC + PIT ready (~100Hz)", .{});

        arch.initKeyboard();
        klog.info("Keyboard: PS/2 driver initialized, IRQ1 unmasked", .{});

        arch.initMouse();
        klog.info("Mouse: PS/2 driver initialized, IRQ12 unmasked", .{});

        arch.enableInterrupts();
        klog.info("Interrupts enabled", .{});
    }

    // ═══ Phase 3: VM + Page Tables ═══
    klog.info("--- Phase 3: VM + Page Tables ---", .{});

    var kernel_space = vm.createAddressSpace(&alloc) orelse {
        klog.err("Failed to create kernel address space", .{});
        arch.halt();
    };

    const min_pages = (kernel_end / paging.page_size) + 4096;
    const min_512mb: usize = 131072; // 512MB / 4KB = 131072 pages
    const identity_pages: usize = if (min_pages < min_512mb) min_512mb else if (min_pages < 262144) min_pages else 262144;
    const id_bytes: u64 = @as(u64, @intCast(identity_pages)) * @as(u64, @intCast(paging.page_size));
    klog.info("VM: Identity mapping %u pages (%uMB)", .{
        identity_pages, identity_pages * paging.page_size / (1024 * 1024),
    });
    const id_st = vm.mapIdentityByteRange(&kernel_space, 0, id_bytes, .{ .writable = true, .executable = true }) orelse {
        klog.err("VM: Identity map failed (mapIdentityByteRange)", .{});
        arch.halt();
    };
    klog.info("VM: Identity 0-%uMB OK (huge2m=%u leaf=%u)", .{
        identity_pages * paging.page_size / (1024 * 1024),
        id_st.x86_huge_2m,
        id_st.leaf_pages,
    });

    if (builtin.cpu.arch == .x86_64) {
        if (boot_info) |bi| {
            if (bi.acpi_rsdp_phys != 0) {
                const acpi_pci = @import("hal/x86_64/acpi_pci_early.zig");
                const madt = @import("hal/x86_64/madt.zig");
                acpi_pci.initFromRsdp(bi.acpi_rsdp_phys);
                madt.initFromRsdp(bi.acpi_rsdp_phys);
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

    kernel_space.activate();
    vm.bindKernelAddressSpace(&kernel_space);
    klog.info("VM: Kernel page tables loaded", .{});

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

    const phys_buddy = @import("mm/phys_buddy.zig");
    phys_buddy.initKernelContiguousBuddy(&alloc);
    if (phys_buddy.kernelContiguousBuddyReady()) {
        klog.info("PhysBuddy: contiguous arena leaf_pages=%u (order<=%u)", .{
            phys_buddy.kernelContiguousLeafPages(),
            phys_buddy.kernel_contiguous_max_order,
        });
    } else {
        klog.warn("PhysBuddy: no contiguous carve (DMA multi-page may use bitmap scan only)", .{});
    }

    // ═══ Phase 4: Object / Handle / Process Core ═══
    klog.info("--- Phase 4: Object / Handle / Process Core ---", .{});

    ob.init();
    ob.initNamespace();
    se.init();
    io.init();

    // ═══ Phase 5: IPC + System Services ═══
    klog.info("--- Phase 5: IPC + System Services ---", .{});

    server.init(&alloc);

    _ = port.createPort(1, "\\LPC\\PsServer");
    _ = port.createPort(1, "\\LPC\\ObServer");
    _ = port.createPort(1, "\\LPC\\IoServer");
    klog.info("LPC: System service ports created", .{});

    smss.init(&alloc);

    // ═══ Phase 6: I/O + File System + Driver ═══
    klog.info("--- Phase 6: I/O + File + Driver ---", .{});

    drivers.init();
    drivers.initInputDrivers();
    drivers.initAudioDrivers();

    vfs_mod.init();
    fat32_mod.init();
    ntfs_mod.init();
    virtio_blk_scratch_fs.mountIfVirtioBlkDetected();

    registry.init();

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
        enterDesktopSession(
            &alloc,
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
    klog.info("Processes    : %u", .{@import("ps/process.zig").getProcessCount()});
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

fn desktopThemeFromBuildDefault(s: []const u8) @import("arch.zig").impl.boot.DesktopTheme {
    if (std.mem.eql(u8, s, "none")) return .none;
    return .aero;
}

fn desktopThemeName(theme: @import("arch.zig").impl.boot.DesktopTheme) []const u8 {
    return switch (theme) {
        .none => "none",
        .aero => "aero",
    };
}

fn initDesktopFramebufferFromHandoff(
    binfo: *const arch.impl.boot.BootInfo,
    comptime extended_scanout_setup: bool,
) void {
    const drivers = @import("drivers/mod.zig");
    const display = drivers.video.display;
    const user32_mod = @import("subsystems/win32/user32.zig");

    const fb_i = binfo.fb_info orelse return;
    if (fb_i.width == 0 or fb_i.height == 0 or fb_i.bpp == 0) return;

    const use_fb = drivers.video.desktop_fb_resolve.resolveDesktopFramebuffer(.{
        .addr = fb_i.addr,
        .width = fb_i.width,
        .height = fb_i.height,
        .pitch = fb_i.pitch,
        .bpp = fb_i.bpp,
        .pixel_bgr = if (extended_scanout_setup)
            (if (builtin.target.cpu.arch == .x86_64) (fb_i.pixel_bgr != 0) else true)
        else
            (fb_i.pixel_bgr != 0),
    });
    const fb_addr = @as(usize, @truncate(use_fb.addr));

    if (extended_scanout_setup) {
        if (builtin.target.cpu.arch == .loongarch64) {
            const vm = @import("mm/vm.zig");
            const ramfb_la = @import("hal/loongarch64/ramfb.zig");
            const fb_bytes = @as(usize, use_fb.pitch) * @as(usize, use_fb.height);
            if (vm.remapIdentityRangeUncached(fb_addr, fb_bytes)) {
                klog.info("VM: LoongArch scanout FB 0x%x size 0x%x → MAT_WUC (GOP/ramfb scanout)", .{
                    fb_addr, fb_bytes,
                });
            } else {
                klog.warn("VM: LoongArch framebuffer uncached remap failed — desktop may not scan out", .{});
            }
            if (ramfb_la.pointRamfbToGuestPhys(
                use_fb.addr,
                use_fb.width,
                use_fb.height,
                use_fb.pitch,
            )) {
                klog.info("ramfb: pointed QEMU scanout to GOP phys 0x%x (%ux%u stride %u)", .{
                    @as(usize, @truncate(use_fb.addr)),
                    use_fb.width,
                    use_fb.height,
                    use_fb.pitch,
                });
            } else if (klog.DEBUG_MODE) {
                klog.info("ramfb: pointRamfbToGuestPhys skipped (no etc/ramfb — OK if no -device ramfb)", .{});
            }
        }
        if (builtin.target.cpu.arch == .aarch64) {
            const a64r = @import("hal/aarch64/ramfb.zig");
            if (a64r.pointRamfbToGuestPhys(use_fb.addr, use_fb.width, use_fb.height, use_fb.pitch)) {
                klog.info("ramfb(a64): QEMU scanout → guest phys 0x%x", .{@as(usize, @truncate(use_fb.addr))});
            } else if (klog.DEBUG_MODE) {
                klog.info("ramfb(a64): pointRamfbToGuestPhys skipped", .{});
            }
        }
        if (builtin.target.cpu.arch == .riscv64) {
            const rvr = @import("hal/riscv64/ramfb.zig");
            if (rvr.pointRamfbToGuestPhys(use_fb.addr, use_fb.width, use_fb.height, use_fb.pitch)) {
                klog.info("ramfb(rv): QEMU scanout → guest phys 0x%x", .{@as(usize, @truncate(use_fb.addr))});
            } else if (klog.DEBUG_MODE) {
                klog.info("ramfb(rv): pointRamfbToGuestPhys skipped", .{});
            }
        }
    }

    if (!arch.impl.framebuffer.isReady()) {
        arch.initFramebuffer(fb_addr, use_fb.width, use_fb.height, use_fb.pitch, use_fb.bpp);
    }
    arch.impl.framebuffer.setConsoleEnabled(false);
    drivers.initDesktopMode(fb_addr, use_fb.width, use_fb.height, use_fb.pitch, use_fb.bpp, use_fb.pixel_bgr);
    user32_mod.syncScreenFromFramebuffer();
    display.syncCursorFromMouse();
    display.clearFramebuffer();
}

fn runDesktopMainLoop(comptime bisect_log_prefix: []const u8) noreturn {
    const drivers = @import("drivers/mod.zig");
    const display = drivers.video.display;
    const startmenu_mod = @import("drivers/video/startmenu.zig");
    const builtin_apps_mod = @import("drivers/video/builtin_apps.zig");
    const mouse = @import("drivers/input/mouse.zig");
    const input_hub = @import("drivers/input/input_hub.zig");
    const mouse_debug = @import("drivers/input/mouse_debug.zig");
    const virtio_input_pci = @import("drivers/input/virtio_input_pci.zig");
    const display_flip_journal = @import("drivers/video/display_flip_journal.zig");
    const scheduler = @import("ke/scheduler.zig");

    var prev_buttons: u8 = 0;
    var idle_streak: u32 = 0;
    var last_draw_cx: i32 = mouse.getX();
    var last_draw_cy: i32 = mouse.getY();
    const desktop_extra_input_polls: u32 = if (builtin.target.cpu.arch == .loongarch64) 32 else 16;

    const panic_ctx = @import("rtl/panic_context.zig");
    while (true) {
        panic_ctx.setPhase(0x0001_0001);
        input_hub.pollAll();
        const nudge = arch.takeCursorNudge();
        if (nudge.dx != 0 or nudge.dy != 0) mouse.injectNudge(nudge.dx, nudge.dy);

        var needs_ui_paint = false;
        var move_paint = display.MouseMovePaintHint{};
        var pop_count: u32 = 0;

        while (mouse.popEvent()) |event| {
            pop_count +%= 1;
            const cur_buttons = event.buttons;

            move_paint = display.MouseMovePaintHint.merge(move_paint, display.handleMouseMove(mouse.getX(), mouse.getY()));

            if (event.scroll != 0) {
                needs_ui_paint = true;
            }

            if (cur_buttons != prev_buttons) {
                if (cur_buttons & 0x01 != 0 and prev_buttons & 0x01 == 0) {
                    if (display.handleClick(mouse.getX(), mouse.getY())) needs_ui_paint = true;
                }
                if (cur_buttons & 0x01 == 0 and prev_buttons & 0x01 != 0) {
                    if (display.handleMouseRelease()) needs_ui_paint = true;
                }
                if (cur_buttons & 0x02 != 0 and prev_buttons & 0x02 == 0) {
                    if (display.handleRightClick(mouse.getX(), mouse.getY())) needs_ui_paint = true;
                }
            }

            prev_buttons = cur_buttons;
        }

        input_hub.pollAll();
        move_paint = display.MouseMovePaintHint.merge(move_paint, display.handleMouseMove(mouse.getX(), mouse.getY()));

        if (display.handleDesktopHotkeys()) needs_ui_paint = true;
        if (startmenu_mod.feedSearchFromKeyboard()) needs_ui_paint = true;
        if (builtin_apps_mod.pollKeyboardToFocused()) needs_ui_paint = true;

        const mx = mouse.getX();
        const my = mouse.getY();
        mouse_debug.desktopHeartbeat(mx, my, virtio_input_pci.isActive());
        const pixel_moved = (mx != last_draw_cx or my != last_draw_cy);
        const scene_dirty = needs_ui_paint or move_paint.needs_full_scene;
        const interpolating = mouse.isInterpolating();
        const startmenu_repaint = move_paint.needs_startmenu_repaint;
        const drag_repaint = move_paint.needs_drag_repaint;
        const shell_geometry_repaint = move_paint.needs_shell_frame_repaint;
        const caption_chrome_only = move_paint.needs_caption_chrome_only;
        const cursor_dirty = pixel_moved or mouse.hasCursorMoved() or move_paint.cursor_shape_changed;

        // `interpolating` 不可删：`interpolateStep` 在 `renderDesktopFrameEx` 内执行；仅靠 `pixel_moved` 会在插值中间帧漏绘。
        // 全屏重绘仅在 `display.renderDesktopFrameEx` 中 `moveOnly` 失败时回退（壳层打开时优先光标快路径）。
        const need_paint = scene_dirty or cursor_dirty or caption_chrome_only or drag_repaint or startmenu_repaint or shell_geometry_repaint or interpolating;

        mouse_debug.setEventsPoppedLastTick(pop_count);

        if (need_paint) {
            const bisect = @import("build_options").desktop_bisect;
            const t0 = if (bisect) scheduler.getTicks() else 0;
            if (bisect) {
                klog.debug("%s: pre renderDesktopFrameEx scene_dirty=%u caption=%u drag=%u sm=%u fb_w=%u", .{
                    bisect_log_prefix,
                    @intFromBool(scene_dirty),
                    @intFromBool(caption_chrome_only),
                    @intFromBool(drag_repaint),
                    @intFromBool(startmenu_repaint),
                    display.desktopFramebufferWidth(),
                });
            }
            display.renderDesktopFrameEx(scene_dirty, caption_chrome_only, drag_repaint, startmenu_repaint, shell_geometry_repaint);
            if (bisect) {
                klog.debug("%s: post renderDesktopFrameEx pre-present ticks=%u", .{
                    bisect_log_prefix,
                    @as(u32, @truncate(scheduler.getTicks() - t0)),
                });
            }
            display.present();
            last_draw_cx = mouse.getX();
            last_draw_cy = mouse.getY();
            idle_streak = 0;
        } else {
            idle_streak +|= 1;
            if (mouse.hasCursorMoved()) {
                mouse.clearCursorMoved();
            }
        }

        const tail_polls = display_flip_journal.extraInputPollBudget(desktop_extra_input_polls, idle_streak);
        for (0..tail_polls) |_| input_hub.pollAll();
        arch.waitForInterruptDesktop();
    }
}

fn enterDesktopSession(
    alloc: *@import("mm/frame.zig").FrameAllocator,
    boot_info_opt: ?arch.impl.boot.BootInfo,
    desktop_theme: arch.impl.boot.DesktopTheme,
    comptime extended_scanout: bool,
    comptime verbose_dwm_klog: bool,
    comptime log_dwm_session: bool,
    comptime bisect_prefix: []const u8,
    comptime not_ready_msg: []const u8,
) void {
    const drivers = @import("drivers/mod.zig");
    const display = drivers.video.display;

    klog.info("Desktop: Preparing %s theme...", .{desktopThemeName(desktop_theme)});
    arch.impl.framebuffer.setConsoleEnabled(false);

    if (boot_info_opt) |binfo| {
        if (binfo.fb_info) |fb_i| {
            if (fb_i.width > 0 and fb_i.height > 0 and fb_i.bpp > 0) {
                initDesktopFramebufferFromHandoff(&binfo, extended_scanout);
            }
        }
    }

    display.setTheme(.aero);
    display.initAeroDwm();
    if (verbose_dwm_klog) {
        klog.info("Desktop: DWM Aero compositor initialized (glass+shadow+smooth_cursor)", .{});
    } else {
        klog.info("Desktop: DWM Aero compositor initialized", .{});
    }

    if (!drivers.isDesktopReady()) {
        klog.err("%s", .{not_ready_msg});
        return;
    }

    klog.info("Desktop: Rendering %s theme", .{desktopThemeName(desktop_theme)});

    const ps_proc = @import("ps/process.zig");
    if (ps_proc.createSystemProcess(alloc, "dwm.exe")) |shell| {
        const ui_tid = ps_proc.allocTid() orelse 0;
        ps_proc.registerDesktopSession(shell.pid, ui_tid);
        ps_proc.setCurrentProcess(shell.pid);
        if (log_dwm_session) {
            klog.info("Desktop: session shell PID=%u UI_TID=%u (dwm.exe)", .{ shell.pid, ui_tid });
        }
    } else {
        if (log_dwm_session) {
            klog.warn("Desktop: could not register dwm.exe shell process (table full?)", .{});
        }
    }

    display.renderAeroDesktop();
    display.present();
    // LoongArch + ramfb：部分 QEMU 组合在首帧像素落盘后再 point 一次 fw_cfg，主窗更易绑定到实际扫描缓冲（AeroDesktopRuntime.md）。
    if (extended_scanout and builtin.target.cpu.arch == .loongarch64) {
        const fb_drv = drivers.video.framebuffer;
        const gaddr = fb_drv.getAddress();
        fb_drv.fenceScanoutVisibleWrites();
        const ramfb_la = @import("hal/loongarch64/ramfb.zig");
        const gw = fb_drv.getWidth();
        const gh = fb_drv.getHeight();
        const gp = fb_drv.getPitch();
        if (gw > 0 and gh > 0 and gp > 0) {
            _ = ramfb_la.pointRamfbToGuestPhys(@as(u64, @truncate(gaddr)), gw, gh, gp);
        }
    }
    drivers.video.framebuffer.logFramebufferMemorySummary();
    klog.info("Desktop: first frame presented (taskbar+shell+cursor)", .{});

    runDesktopMainLoop(bisect_prefix);
}

// ── ZBM 串口菜单（与 boot/zbm/uefi/main_loongarch64.zig 样式对齐：箭头、边框、描述、ENTER/ESC）──
fn showZbmStyleBootMenu() void {
    const sys_config = @import("config/config.zig");
    const COUNTDOWN_SEC: u32 = 10;
    var countdown: u32 = COUNTDOWN_SEC;
    var selected: usize = 0;
    const entries = [_][]const u8{
        "ZirconOSAero (NT 6.1)",
        "ZirconOSAero (NT 6.1) [Debug Mode]",
        "ZirconOSAero [Safe Mode]",
        "ZirconOSAero [Safe Mode with Networking]",
        "ZirconOSAero [Recovery Console]",
        "ZirconOSAero [CMD Shell]",
    };
    const descriptions = [_][]const u8{
        "Start ZirconOSAero normally.",
        "Start with debug logging and serial output enabled.",
        "Start with minimal drivers and services.",
        "Start in safe mode with network support.",
        "Start the Recovery Console for system repair.",
        "Use the last configuration that worked.",
    };
    var esc_seq: u32 = 0;

    var need_full_redraw: bool = true;
    while (true) {
        if (need_full_redraw) {
            klog.info("", .{});
            klog.info("                 ZirconOSAero Boot Manager (NT 6.1)                            ", .{});
            klog.info("                         Version %s                                             ", .{sys_config.getVersion()});
            klog.info("", .{});
            klog.info("    Choose an operating system to start:", .{});
            klog.info("    (Use the arrow keys to highlight your choice, then press ENTER.)", .{});
            klog.info("", .{});
            for (entries, 0..) |e, i| {
                if (i == selected) {
                    klog.info("  > %s", .{e});
                } else {
                    klog.info("    %s", .{e});
                }
            }
            klog.info("", .{});
            klog.info("    ------------------------------------------------------------------------", .{});
            klog.info("", .{});
            klog.info("    %s", .{descriptions[selected]});
            klog.info("", .{});
            klog.info("  ENTER=Choose  |  ESC=Advanced Options  |  F1=Help                          ", .{});
            klog.info("", .{});
            klog.info("    Architecture: loongarch64  |  Boot: kernel direct (-kernel)", .{});
            need_full_redraw = false;
        }
        if (countdown == 0) break;
        klog.info("    Seconds until the highlighted choice will be started automatically: %u", .{countdown});
        var tick: u32 = 0;
        while (tick < 10) : (tick += 1) {
            arch.stallApproxMs(100);
            if (arch.serialReadByte()) |c| {
                if (c == 0x1B) {
                    esc_seq = 1;
                } else if (esc_seq == 1 and c == '[') {
                    esc_seq = 2;
                } else if (esc_seq == 2) {
                    esc_seq = 0;
                    if (c == 'A' and selected > 0) {
                        selected -= 1;
                        need_full_redraw = true;
                    }
                    if (c == 'B' and selected + 1 < entries.len) {
                        selected += 1;
                        need_full_redraw = true;
                    }
                } else {
                    esc_seq = 0;
                    if (c == '\r' or c == '\n') return;
                    if (c >= '1' and c <= '6') {
                        const idx = @as(usize, c - '1');
                        if (idx < entries.len) return;
                    }
                }
            }
        }
        countdown -= 1;
    }
}

fn startGeneric(magic: u32, info_addr: usize) noreturn {
    const boot = arch.impl.boot;
    const vm = @import("mm/vm.zig");
    var loong_kernel_space: ?vm.AddressSpace = null;
    const frame = @import("mm/frame.zig");
    const heap = @import("mm/heap.zig");
    const heap_boot = @import("mm/heap_boot.zig");
    const server = @import("servers/server.zig");
    const smss = @import("servers/smss.zig");
    const ob = @import("ob/object.zig");
    const se = @import("se/token.zig");
    const io = @import("io/io.zig");
    const scheduler = @import("ke/scheduler.zig");
    const timer = @import("ke/timer.zig");
    const port = @import("lpc/port.zig");
    const vfs_mod = @import("fs/vfs.zig");
    const fat32_mod = @import("fs/fat32.zig");
    const ntfs_mod = @import("fs/ntfs.zig");
    const pe_loader = @import("loader/pe.zig");
    const elf_loader = @import("loader/elf.zig");
    const ntdll = @import("libs/ntdll.zig");
    const kernel32 = @import("libs/kernel32.zig");
    const console_mod = @import("subsystems/win32/console.zig");
    const cmd_mod = @import("subsystems/win32/cmd.zig");
    const subsys = @import("subsystems/win32/subsystem.zig");
    const exec = @import("subsystems/win32/exec.zig");
    const user32_mod = @import("subsystems/win32/user32.zig");
    const gdi32_mod = @import("subsystems/win32/gdi32.zig");
    const wow64_mod = @import("subsystems/win32/wow64.zig");
    const sys_config = @import("config/config.zig");
    const audio = @import("drivers/audio/audio.zig");
    const registry = @import("registry/registry.zig");
    const virtio_blk_scratch_fs = @import("drivers/storage/virtio_blk_scratch_fs.zig");

    arch.initSerial();

    // 极早 handoff 诊断（UEFI→内核）：区分「未进内核」与「进内核后崩溃」；与 ZBM 写入的 mb2_phys 对照。
    switch (builtin.target.cpu.arch) {
        .aarch64 => {
            const ab = @import("arch/aarch64/boot.zig");
            klog.info("HandoffDiag(a64): multiboot_magic=0x%x reg_x1=0x%x vec_mb2_phys=0x%x", .{
                magic, info_addr, ab.uefiVectorMb2PhysForDiag(),
            });
        },
        .riscv64 => {
            const rb = @import("arch/riscv64/boot.zig");
            klog.info("HandoffDiag(rv): multiboot_magic=0x%x reg_a1=0x%x vec_mb2_phys=0x%x (UART MMIO 0x10000000)", .{
                magic, info_addr, rb.uefiVectorMb2PhysForDiag(),
            });
        },
        else => {},
    }

    klog.info("========================================", .{});
    klog.info("  ZirconOSAero (NT 6.1 hybrid kernel)", .{});
    klog.info("  Architecture: %s", .{arch.impl.name});
    klog.info("========================================", .{});

    if (klog.DEBUG_MODE) {
        klog.info("Build: DEBUG mode (verbose logging enabled)", .{});
    } else {
        klog.info("Build: RELEASE mode (optimized)", .{});
    }

    klog.info("--- Loading System Configuration ---", .{});
    sys_config.init();
    klog.info("Config: %u total entries loaded", .{sys_config.getTotalConfigEntries()});

    klog.info("--- Phase 1: Boot + Early Kernel ---", .{});

    var boot_info = boot.parse(magic, info_addr);

    if (builtin.target.cpu.arch == .aarch64) {
        if (boot_info) |bi| {
            klog.info("BootHandoff(a64): mmap_entries=%u mem_upper_kb=%u multiboot_fb=%s", .{
                bi.mmap_entry_count,
                bi.mem_upper_kb,
                if (bi.fb_info != null) "yes" else "no",
            });
        } else {
            klog.warn("BootHandoff(a64): boot.parse returned null", .{});
        }
    }
    if (builtin.target.cpu.arch == .riscv64) {
        if (boot_info) |bi| {
            klog.info("BootHandoff(rv): mmap_entries=%u mem_upper_kb=%u multiboot_fb=%s", .{
                bi.mmap_entry_count,
                bi.mem_upper_kb,
                if (bi.fb_info != null) "yes" else "no",
            });
        } else {
            klog.warn("BootHandoff(rv): boot.parse returned null", .{});
        }
    }

    var alloc: frame.FrameAllocator = undefined;
    // LoongArch：尽早初始化 alloc + VM，map 2GB 以覆盖 GOP framebuffer（可能 >512MB）
    if (builtin.target.cpu.arch == .loongarch64) {
        // 首选分辨率：`sys_config` 嵌入的 desktop.conf `[resolution]`（由 sync_resolution_config 与 build.conf 对齐）；无效时回退 build_options。
        const bo_w = @import("build_options").kernel_preferred_fb_width;
        const bo_h = @import("build_options").kernel_preferred_fb_height;
        const cw64 = sys_config.getResolutionWidth();
        const ch64 = sys_config.getResolutionHeight();
        var pref_w: u32 = if (cw64 >= 320 and cw64 <= 16384) @truncate(cw64) else bo_w;
        var pref_h: u32 = if (ch64 >= 240 and ch64 <= 16384) @truncate(ch64) else bo_h;
        if (pref_w == 0) pref_w = if (bo_w != 0) bo_w else 1024;
        if (pref_h == 0) pref_h = if (bo_h != 0) bo_h else 768;

        var loong_discarded_gop: ?boot.FramebufferInfo = null;

        // QEMU GTK 往往只扫「固件 GOP」窗口；若 ZBM 已将 GOP SetMode 到 ≥1024×768，handoff 与该窗口同源，应直接使用。
        // 否则丢弃过小/非线性 GOP，由 ramfb.setupWithDims 写 0xF000000（部分 QEMU 配置下窗口仍不跟 ramfb，见文档）。
        if (boot_info) |bi_in| {
            var bi_mut = bi_in;
            const gop_ok = if (bi_mut.fb_info) |fb| blk: {
                if (fb.addr == 0 or fb.bpp != 32) break :blk false;
                if (fb.width < 1024 or fb.height < 768) break :blk false;
                // 与 build.conf / ZBM 首选一致：固件 GOP 常仅为 1024×768；低于首选则改用 ramfb+fw_cfg（常为 1920×1080）
                if (pref_w != 0 and pref_h != 0 and (fb.width < pref_w or fb.height < pref_h)) {
                    klog.info("Display: GOP %ux%u below build preferred %ux%u; ramfb @ RAMFB_PHYS", .{
                        fb.width, fb.height, pref_w, pref_h,
                    });
                    break :blk false;
                }
                break :blk true;
            } else false;
            if (!gop_ok) {
                if (bi_mut.fb_info) |fb| {
                    const skipped_as_below_pref = pref_w != 0 and pref_h != 0 and
                        (fb.width < pref_w or fb.height < pref_h);
                    if (!skipped_as_below_pref) {
                        klog.info("Display: GOP %ux%u not used (min/resolution/bpp); ramfb @ RAMFB_PHYS", .{
                            fb.width, fb.height,
                        });
                    }
                }
                loong_discarded_gop = bi_mut.fb_info;
                bi_mut.fb_info = null;
            } else {
                klog.info("Display: using UEFI GOP %ux%u (meets preferred %ux%u)", .{
                    bi_mut.fb_info.?.width, bi_mut.fb_info.?.height, pref_w, pref_h,
                });
            }
            boot_info = bi_mut;
        }
        // 勿用固定 0x400000：链接脚本下映像+BSS+1MiB 栈后 _kernel_end 常 >4MiB，否则页表帧会分配到内核/栈物理页，identity map 约在 8MiB 处失败。
        // `_kernel_end` 为零尺寸链接器符号：勿用 @intFromPtr(&_)（LoongArch 上可能为 0）；见 arch/loongarch64/mod.zig `linkerKernelEndExclusive`。
        const la_k_end = (arch.impl.linkerKernelEndExclusive() + frame.FRAME_SIZE - 1) & ~@as(usize, frame.FRAME_SIZE - 1);
        klog.info("Memory: LoongArch kernel_end=0x%x (_kernel_end aligned)", .{la_k_end});
        alloc.init(boot_info, la_k_end);
        frame.setKernelFrameAllocator(&alloc);

        const ramfb = @import("hal/loongarch64/ramfb.zig");
        // QEMU ramfb 扫描使用固定 GPA 0x0F000000..；若在此之后才对 `markPhysRangeUsed`，
        // `createAddressSpace` 的页表帧可能已分配到该区间，与屏缓冲重叠 → 缺页/花屏/「无法进桌面」。
        // 仅 1024×768 等与 GOP 一致时保留 handoff、不走 ramfb，故以往不易触发。
        const need_ramfb_scanout = if (boot_info) |b|
            (b.fb_info == null or b.fb_info.?.addr == 0)
        else
            true;
        if (need_ramfb_scanout) {
            const ramfb_rsv = ramfb.framebufferReservedBytesDims(pref_w, pref_h);
            if (ramfb_rsv > 0) {
                alloc.markPhysRangeUsed(ramfb.RAMFB_PHYS, ramfb_rsv);
                klog.info("LoongArch: ramfb scanout reserved %u bytes @0x%x (before page tables)", .{
                    @as(u32, @truncate(ramfb_rsv)), ramfb.RAMFB_PHYS,
                });
            }
        }

        const paging = arch.impl.paging;
        if (vm.createAddressSpace(&alloc)) |ks| {
            loong_kernel_space = ks;
            const kernel_space = &loong_kernel_space.?;
            // 0–2GiB：GOP/ramfb；GPU MMIO 若落在 2–4GiB，`vm.mapDeviceMmioIdentity` 会按需建 identity 非缓存映射
            const identity_pages: usize = (2 * 1024 * 1024 * 1024) / paging.page_size;
            const id_limit: usize = identity_pages * paging.page_size;
            const id_bytes_la: u64 = @as(u64, @intCast(id_limit));
            const la_id_st = vm.mapIdentityByteRange(kernel_space, 0, id_bytes_la, .{ .writable = true, .executable = true }) orelse {
                klog.err("LoongArch: identity map failed (mapIdentityByteRange)", .{});
                arch.halt();
            };
            klog.info("VM: LoongArch identity stats la32m=%u leaf=%u", .{
                la_id_st.la_blocks_32m, la_id_st.leaf_pages,
            });
            // virtio-gpu / 部分固件 GOP 帧缓冲落在 PCI BAR（物理地址 ≥2GiB）；仅 map 低 2GiB 时访问桌面会缺页
            if (boot_info) |binfo| {
                if (binfo.fb_info) |fb_i| {
                    if (fb_i.addr != 0 and fb_i.height > 0 and fb_i.pitch > 0) {
                        const fb_base = @as(usize, @truncate(fb_i.addr)) & ~@as(usize, paging.page_size - 1);
                        const fb_bytes = @as(usize, fb_i.pitch) * @as(usize, fb_i.height);
                        if (fb_bytes != 0) {
                            const fb_end = fb_base + fb_bytes;
                            const va_limit = (fb_end + paging.page_size - 1) & ~@as(usize, paging.page_size - 1);
                            const map_lo = @max(fb_base, id_limit);
                            if (map_lo < va_limit) {
                                const fb_flags = vm.MapFlags{ .writable = true, .executable = false, .no_cache = true };
                                const spill_len = @as(u64, @intCast(va_limit - map_lo));
                                _ = vm.mapIdentityByteRange(kernel_space, @as(u64, @intCast(map_lo)), spill_len, fb_flags) orelse {
                                    klog.err("LoongArch: framebuffer spill map failed 0x%x", .{map_lo});
                                    arch.halt();
                                };
                            }
                            if (fb_base >= id_limit or fb_end > id_limit) {
                                klog.info("VM: LoongArch scanout FB 0x%x..0x%x (touched ≥2GiB; extra uncached PTEs)", .{
                                    fb_base, fb_end,
                                });
                            }
                        }
                    }
                }
            }
            kernel_space.activate();
            vm.bindKernelAddressSpace(kernel_space);
            klog.info("VM: LoongArch identity map 0-2GB (covers GOP fb; BAR>2G via mapDeviceMmioIdentity)", .{});
        }
        const has_gop_fb = if (boot_info) |b| (b.fb_info != null and b.fb_info.?.addr != 0) else false;
        if (!has_gop_fb) {
            if (ramfb.setupWithDims(pref_w, pref_h)) |fb_i| {
                var bi = boot_info orelse boot.BootInfo{};
                bi.fb_info = .{
                    .addr = fb_i.addr,
                    .pitch = fb_i.pitch,
                    .width = fb_i.width,
                    .height = fb_i.height,
                    .bpp = fb_i.bpp,
                    .fb_type = fb_i.fb_type,
                };
                boot_info = bi;
                const rsv = ramfb.framebufferReservedBytesDims(fb_i.width, fb_i.height);
                if (rsv > 0) {
                    alloc.markPhysRangeUsed(@as(usize, @truncate(fb_i.addr)), rsv);
                }
                klog.info("ramfb: %ux%u@%u addr=0x%x", .{
                    fb_i.width,                       fb_i.height, fb_i.bpp,
                    @as(usize, @truncate(fb_i.addr)),
                });
            } else {
                klog.warn("ramfb: setupWithDims failed — no framebuffer (check QEMU -device ramfb and fw_cfg etc/ramfb; see docs/cn/AeroDesktopRuntime.md LoongArch GOP vs ramfb)", .{});
                if (loong_discarded_gop) |dg| {
                    if (dg.addr != 0 and dg.bpp == 32 and dg.width >= 1024 and dg.height >= 768) {
                        var bi = boot_info orelse boot.BootInfo{};
                        bi.fb_info = dg;
                        boot_info = bi;
                        klog.warn("LoongArch: restored UEFI GOP %ux%u (ramfb/fw_cfg failed; desktop at firmware res)", .{
                            dg.width, dg.height,
                        });
                    }
                }
            }
        } else {
            klog.info("Display: using GOP framebuffer from handoff (same surface as firmware)", .{});
        }
    }

    // LoongArch -kernel 直启无 EFI handoff 时显示 ZBM 风格操作系统选择菜单（串口）
    const zircon_magic: u32 = 0x6372697A;
    const has_handoff = (magic == zircon_magic and info_addr != 0);
    if (builtin.target.cpu.arch == .loongarch64 and !has_handoff) {
        showZbmStyleBootMenu();
    }

    if (builtin.target.cpu.arch != .loongarch64) {
        const k_reserved = (@intFromPtr(&_kernel_end) + 4095) & ~@as(usize, 4095);
        alloc.init(boot_info, k_reserved);
        frame.setKernelFrameAllocator(&alloc);
    }

    // QEMU virt：启用自有页表并 identity map，否则 ExitBootServices 后 VirtIO PCI / ECAM 访问不可靠
    var virt_qemu_kernel_space: ?vm.AddressSpace = null;
    if (builtin.target.cpu.arch == .aarch64) {
        const paging = arch.impl.paging;
        if (vm.createAddressSpace(&alloc)) |ks| {
            virt_qemu_kernel_space = ks;
            const ksp = &virt_qemu_kernel_space.?;
            const npg = (2 * 1024 * 1024 * 1024) / paging.page_size;
            const id_limit: usize = npg * paging.page_size;
            var ip: usize = 0;
            while (ip < npg) : (ip += 1) {
                const v = ip * paging.page_size;
                _ = ksp.mapPage(v, v, .{ .writable = true, .executable = true });
            }
            // virtio-gpu / GOP 帧缓冲可落在 PCI BAR（物理 ≥2GiB）；勿对 AArch64 用 no_cache（MAIR_EL1 未配全）
            if (boot_info) |binfo| {
                if (binfo.fb_info) |fb_i| {
                    if (fb_i.addr != 0 and fb_i.height > 0 and fb_i.pitch > 0) {
                        const fb_base = @as(usize, @truncate(fb_i.addr)) & ~@as(usize, paging.page_size - 1);
                        const fb_bytes = @as(usize, fb_i.pitch) * @as(usize, fb_i.height);
                        if (fb_bytes != 0) {
                            const fb_end = fb_base + fb_bytes;
                            const va_limit = (fb_end + paging.page_size - 1) & ~@as(usize, paging.page_size - 1);
                            const map_lo = @max(fb_base, id_limit);
                            if (map_lo < va_limit) {
                                const spill_len = @as(u64, @intCast(va_limit - map_lo));
                                const fb_flags = vm.MapFlags{ .writable = true, .executable = false, .no_cache = false };
                                _ = vm.mapIdentityByteRange(ksp, @as(u64, @intCast(map_lo)), spill_len, fb_flags) orelse {
                                    klog.err("AArch64: framebuffer spill map failed 0x%x", .{map_lo});
                                    arch.halt();
                                };
                            }
                            if (fb_base >= id_limit or fb_end > id_limit) {
                                klog.info("VM: AArch64 scanout FB spill 0x%x..0x%x", .{ fb_base, fb_end });
                            }
                        }
                    }
                }
            }
            ksp.activate();
            vm.bindKernelAddressSpace(ksp);
            klog.info("VM: AArch64 identity map 0-2GiB (PCI ECAM / VirtIO / RAM)", .{});
        }
        // UEFI GOP 在 QEMU AArch64+virtio-gpu 上常为 BLT-only，ZBM 不传 FB tag → 桌面永不启动；用 ramfb 补全。
        if (boot_info) |*bi| {
            const fb_ok = if (bi.fb_info) |fb|
                (fb.addr != 0 and fb.width >= 640 and fb.height >= 480 and fb.pitch > 0 and fb.bpp == 32)
            else
                false;
            if (!fb_ok) {
                const a64_ramfb = @import("hal/aarch64/ramfb.zig");
                if (a64_ramfb.setup()) |rf| {
                    bi.fb_info = .{
                        .addr = rf.addr,
                        .pitch = rf.pitch,
                        .width = rf.width,
                        .height = rf.height,
                        .bpp = rf.bpp,
                        .fb_type = rf.fb_type,
                        .pixel_bgr = 1,
                    };
                    const rsv = a64_ramfb.framebufferReservedBytes();
                    if (rsv > 0) {
                        alloc.markPhysRangeUsed(@as(usize, @truncate(rf.addr)), rsv);
                    }
                    klog.info("Display: AArch64 ramfb %ux%u @0x%x (no linear UEFI GOP from boot loader)", .{
                        rf.width, rf.height, @as(usize, @truncate(rf.addr)),
                    });
                } else {
                    klog.warn("ramfb(a64): no linear FB and fw_cfg ramfb missing — Aero needs QEMU -device ramfb (see Makefile QEMU_AARCH64_DEVICES)", .{});
                }
            }
        }
    } else if (builtin.target.cpu.arch == .riscv64) {
        const paging = arch.impl.paging;
        if (vm.createAddressSpace(&alloc)) |ks| {
            virt_qemu_kernel_space = ks;
            const ksp = &virt_qemu_kernel_space.?;
            const flags = vm.MapFlags{ .writable = true, .executable = true };
            const n_low = (2 * 1024 * 1024 * 1024) / paging.page_size;
            const id_limit: usize = n_low * paging.page_size;
            var ip: usize = 0;
            while (ip < n_low) : (ip += 1) {
                const v = ip * paging.page_size;
                _ = ksp.mapPage(v, v, flags);
            }
            const ram_pages = (512 * 1024 * 1024) / paging.page_size;
            ip = 0;
            while (ip < ram_pages) : (ip += 1) {
                const v = 0x80000000 + ip * paging.page_size;
                _ = ksp.mapPage(v, v, flags);
            }
            if (boot_info) |binfo| {
                if (binfo.fb_info) |fb_i| {
                    if (fb_i.addr != 0 and fb_i.height > 0 and fb_i.pitch > 0) {
                        const fb_base = @as(usize, @truncate(fb_i.addr)) & ~@as(usize, paging.page_size - 1);
                        const fb_bytes = @as(usize, fb_i.pitch) * @as(usize, fb_i.height);
                        if (fb_bytes != 0) {
                            const fb_end = fb_base + fb_bytes;
                            const va_limit = (fb_end + paging.page_size - 1) & ~@as(usize, paging.page_size - 1);
                            const map_lo = @max(fb_base, id_limit);
                            if (map_lo < va_limit) {
                                const spill_len = @as(u64, @intCast(va_limit - map_lo));
                                const fb_flags = vm.MapFlags{ .writable = true, .executable = false, .no_cache = false };
                                _ = vm.mapIdentityByteRange(ksp, @as(u64, @intCast(map_lo)), spill_len, fb_flags) orelse {
                                    klog.err("RISC-V64: framebuffer spill map failed 0x%x", .{map_lo});
                                    arch.halt();
                                };
                            }
                            if (fb_base >= id_limit or fb_end > id_limit) {
                                klog.info("VM: RISC-V64 scanout FB spill 0x%x..0x%x", .{ fb_base, fb_end });
                            }
                        }
                    }
                }
            }
            ksp.activate();
            vm.bindKernelAddressSpace(ksp);
            klog.info("VM: RISC-V64 identity map low 2GiB + RAM@0x80000000 (512MiB); fw_cfg for ramfb @0x10100000 mapped in low 2GiB", .{});
        }
        if (boot_info) |*bi| {
            const fb_ok = if (bi.fb_info) |fb|
                (fb.addr != 0 and fb.width >= 640 and fb.height >= 480 and fb.pitch > 0 and fb.bpp == 32)
            else
                false;
            if (!fb_ok) {
                const rv_ramfb = @import("hal/riscv64/ramfb.zig");
                if (rv_ramfb.setup()) |rf| {
                    bi.fb_info = .{
                        .addr = rf.addr,
                        .pitch = rf.pitch,
                        .width = rf.width,
                        .height = rf.height,
                        .bpp = rf.bpp,
                        .fb_type = rf.fb_type,
                        .pixel_bgr = 1,
                    };
                    const rsv = rv_ramfb.framebufferReservedBytes();
                    if (rsv > 0) {
                        alloc.markPhysRangeUsed(@as(usize, @truncate(rf.addr)), rsv);
                    }
                    klog.info("Display: RISC-V64 ramfb %ux%u @0x%x (no linear UEFI GOP from boot loader)", .{
                        rf.width, rf.height, @as(usize, @truncate(rf.addr)),
                    });
                } else {
                    klog.warn("ramfb(rv): no linear FB and fw_cfg ramfb missing — add -device ramfb (see Makefile QEMU_RISCV64_EXTRA)", .{});
                }
            }
        }
    }
    if (boot_info) |info| {
        klog.info("Memory: upper=%u KB, mmap_entries=%u", .{
            info.mem_upper_kb, info.mmap_entry_count,
        });
        klog.info("Boot: mode=%u desktop_theme=%u (EFI handoff if magic matches)", .{
            @intFromEnum(info.boot_mode), @intFromEnum(info.desktop_theme),
        });
    }

    klog.info("Frame allocator: total_frames=%u, frame_size=%u", .{
        alloc.total_frames, frame.FRAME_SIZE,
    });

    const heap_kb_gen: u64 = @min(sys_config.getHeapSizeKb(), @as(u64, 512 * 1024));
    const heap_kb_gen32: u32 = @truncate(@min(heap_kb_gen, @as(u64, std.math.maxInt(u32))));
    if (vm.kernelAddressSpace()) |ks| {
        heap_boot.initKernelHeapAfterVm(ks, heap_kb_gen32);
    } else {
        heap.init();
    }
    klog.info("Kernel heap: growable=%u base=0x%x cap=%uKB committed=%uB live=%uB", .{
        @intFromBool(heap.isGrowableBacked()),
        heap.kernelHeapBaseVirt(),
        heap.capacityBytes() / 1024,
        heap.totalBytes(),
        heap.usedBytes(),
    });

    const phys_buddy = @import("mm/phys_buddy.zig");
    phys_buddy.initKernelContiguousBuddy(&alloc);
    if (phys_buddy.kernelContiguousBuddyReady()) {
        klog.info("PhysBuddy: leaf_pages=%u", .{phys_buddy.kernelContiguousLeafPages()});
    } else {
        klog.warn("PhysBuddy: contiguous carve unavailable", .{});
    }

    klog.info("--- Phase 2: Scheduler + Timer ---", .{});
    scheduler.init();
    if (builtin.target.cpu.arch == .loongarch64) {
        @import("arch/loongarch64/traps.zig").init();
    }
    timer.init();
    if (builtin.target.cpu.arch == .loongarch64) {
        arch.enableInterrupts();
        klog.info("LoongArch: CRMD.IE enabled (timer + HWI)", .{});
    }

    klog.info("--- Phase 4: Object / Handle / Process Core ---", .{});
    ob.init();
    ob.initNamespace();
    se.init();
    io.init();

    klog.info("--- Phase 5: IPC + System Services ---", .{});
    server.init(&alloc);
    _ = port.createPort(1, "\\LPC\\PsServer");
    _ = port.createPort(1, "\\LPC\\ObServer");
    _ = port.createPort(1, "\\LPC\\IoServer");
    smss.init(&alloc);

    klog.info("--- Phase 6: I/O + File + Driver ---", .{});
    const drivers_generic = @import("drivers/mod.zig");
    drivers_generic.init();
    drivers_generic.initInputDrivers();
    drivers_generic.initAudioDrivers();
    vfs_mod.init();
    fat32_mod.init();
    ntfs_mod.init();
    virtio_blk_scratch_fs.mountIfVirtioBlkDetected();

    registry.init();
    klog.info("Registry: %u keys in 5 hives", .{registry.getKeyCount()});

    klog.info("--- Phase 7: Loader ---", .{});
    elf_loader.init();
    pe_loader.init();

    klog.info("--- Phase 8: Native Userland ---", .{});
    ntdll.init();
    kernel32.init();
    console_mod.init();
    cmd_mod.init();

    klog.info("--- Phase 9: Win32 Subsystem ---", .{});
    subsys.init();
    exec.init();

    klog.info("--- Phase 10: Graphical Subsystem ---", .{});
    user32_mod.init();
    gdi32_mod.init();
    subsys.initGuiSubsystem();

    klog.info("--- Phase 11: WOW64 + Audio ---", .{});
    wow64_mod.init();
    audio.init();

    klog.info("", .{});
    klog.info("=== ZirconOSAero NT %s kernel ready (Phase 0–12) ===", .{sys_config.getVersion()});
    klog.info("Architecture : %s", .{arch.impl.name});
    klog.info("Processes    : %u", .{@import("ps/process.zig").getProcessCount()});
    klog.info("Sessions     : %u", .{smss.getSessionCount()});
    klog.info("Heap         : %u/%u bytes used", .{ heap.usedBytes(), heap.totalBytes() });
    klog.info("I/O Devices  : %u, Drivers: %u", .{ io.getDeviceCount(), io.getDriverCount() });
    klog.info("", .{});

    audio.playEvent(.startup);

    const boot_mode: boot.BootMode = if (boot_info) |info| info.boot_mode else .normal;
    var desktop_theme: boot.DesktopTheme = if (boot_info) |info| info.desktop_theme else .none;
    if (desktop_theme == .none) {
        desktop_theme = desktopThemeFromBuildDefault(@import("build_options").default_desktop);
    }
    var has_gfx_fb = false;
    if (boot_info) |info| {
        if (info.fb_info) |fb_i| {
            if (fb_i.width > 0 and fb_i.height > 0 and fb_i.bpp > 0) has_gfx_fb = true;
        }
    }
    klog.info("Display: has_gfx_fb=%u desktop=%s", .{
        @intFromBool(has_gfx_fb),
        desktopThemeName(desktop_theme),
    });

    if (boot_mode == .desktop or (boot_mode == .normal and has_gfx_fb and desktop_theme != .none)) {
        enterDesktopSession(
            &alloc,
            boot_info,
            desktop_theme,
            true,
            false,
            false,
            "desktop_generic",
            "Desktop: isDesktopReady=false",
        );
    }

    cmd_mod.runBootSequence();
    exec.runDemoApps();
    gdi32_mod.runGdiDemo();
    user32_mod.runGuiDemo();
    wow64_mod.runWow64Demo();

    klog.info("", .{});
    klog.info("=== System Ready ===", .{});
    klog.info("", .{});

    cmd_mod.runInteractiveShell();
}
