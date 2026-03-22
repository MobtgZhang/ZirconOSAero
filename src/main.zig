const builtin = @import("builtin");
const arch = @import("arch.zig");
const klog = @import("rtl/klog.zig");
const std = @import("std");

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    arch.consoleWrite("KERNEL PANIC: ");
    arch.consoleWrite(msg);
    arch.consoleWrite("\n");
    arch.halt();
}

extern const stack_top: u8;

comptime {
    switch (builtin.target.cpu.arch) {
        .aarch64 => _ = @import("arch/aarch64/mod.zig"),
        .loongarch64 => _ = @import("arch/loongarch64/mod.zig"),
        .riscv64 => _ = @import("arch/riscv64/mod.zig"),
        .mips64el => _ = @import("arch/mips64el/mod.zig"),
        else => {},
    }
}

pub export fn kernel_main(magic: u32, info_addr: usize) callconv(.c) noreturn {
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
    const ps_mod = @import("subsystems/win32/powershell.zig");
    const subsys = @import("subsystems/win32/subsystem.zig");
    const exec = @import("subsystems/win32/exec.zig");
    const user32_mod = @import("subsystems/win32/user32.zig");
    const gdi32_mod = @import("subsystems/win32/gdi32.zig");
    const wow64_mod = @import("subsystems/win32/wow64.zig");
    const sys_config = @import("config/config.zig");
    const drivers = @import("drivers/mod.zig");
    const display = drivers.video.display;
    const audio = @import("drivers/audio/audio.zig");
    const registry = @import("registry/registry.zig");

    // ═══════════════════════════════════════════════════════
    //  Stage A: Early Serial Log  (output: serial only)
    // ═══════════════════════════════════════════════════════
    arch.initSerial();

    klog.info("========================================", .{});
    klog.info("  ZirconOS v1.0 (NT-style Hybrid Microkernel)", .{});
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

    klog.info("Config: hostname=%s, version=%s, arch=%s", .{
        sys_config.getHostname(),
        sys_config.getVersion(),
        sys_config.getArch(),
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
    alloc.init(boot_info, kernel_end, info_addr);
    klog.info("Frame allocator: total_frames=%u, frame_size=%u", .{
        alloc.total_frames, frame.FRAME_SIZE,
    });

    heap.init();
    klog.info("Kernel heap: %u bytes available", .{heap.freeBytes()});

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
    } else if (boot_mode == .powershell) {
        klog.info("Boot mode: PowerShell (direct)", .{});
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
    klog.info("VM: Identity mapping %u pages (%uMB)", .{
        identity_pages, identity_pages * paging.page_size / (1024 * 1024),
    });
    var i: usize = 0;
    while (i < identity_pages) : (i += 1) {
        const virt = i * paging.page_size;
        const flags = vm.MapFlags{ .writable = true, .executable = true };
        if (!kernel_space.mapPage(virt, virt, flags)) {
            klog.err("Identity map failed at 0x%x", .{virt});
            arch.halt();
        }
    }
    klog.info("VM: Identity mapping 0-%uMB OK", .{identity_pages * paging.page_size / (1024 * 1024)});

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
                    var pg = start_page;
                    while (pg < end_page) : (pg += 1) {
                        const addr = pg * paging.page_size;
                        const fb_flags = vm.MapFlags{ .writable = true, .no_cache = true };
                        _ = kernel_space.mapPage(addr, addr, fb_flags);
                    }
                    klog.info("VM: Framebuffer mapped 0x%x-0x%x (%u pages)", .{
                        start_page * paging.page_size, end_page * paging.page_size, end_page - start_page,
                    });
                }
            }
        }
    }

    kernel_space.activate();
    klog.info("VM: Kernel page tables loaded", .{});

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
    ps_mod.init();

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
        klog.info("Desktop: Preparing %s theme...", .{desktopThemeName(desktop_theme)});

        arch.impl.framebuffer.setConsoleEnabled(false);

        if (boot_info) |binfo| {
            if (binfo.fb_info) |fb_i| {
                if (fb_i.width > 0 and fb_i.height > 0 and fb_i.bpp > 0) {
                    const fb_addr = @as(usize, @truncate(fb_i.addr));

                    if (!arch.impl.framebuffer.isReady()) {
                        arch.initFramebuffer(fb_addr, fb_i.width, fb_i.height, fb_i.pitch, fb_i.bpp);
                    }
                    arch.impl.framebuffer.setConsoleEnabled(false);

                    drivers.initDesktopMode(fb_addr, fb_i.width, fb_i.height, fb_i.pitch, fb_i.bpp, fb_i.pixel_bgr != 0);
                    display.syncCursorFromMouse();
                    display.clearFramebuffer();
                }
            }
        }

        display.setTheme(.aero);

        display.initAeroDwm();
        klog.info("Desktop: DWM Aero compositor initialized (glass+shadow+smooth_cursor)", .{});

        if (drivers.isDesktopReady()) {
            klog.info("Desktop: Rendering %s theme", .{desktopThemeName(desktop_theme)});

            // 桌面会话：登记等价于 dwm.exe 的壳进程 + 主 UI 线程号（便于内核统计与后续调度扩展）。
            const ps_proc = @import("ps/process.zig");
            if (ps_proc.createSystemProcess(&alloc, "dwm.exe")) |shell| {
                const ui_tid = ps_proc.allocTid() orelse 0;
                ps_proc.registerDesktopSession(shell.pid, ui_tid);
                ps_proc.setCurrentProcess(shell.pid);
                klog.info("Desktop: session shell PID=%u UI_TID=%u (dwm.exe)", .{ shell.pid, ui_tid });
            } else {
                klog.warn("Desktop: could not register dwm.exe shell process (table full?)", .{});
            }

            display.renderAeroDesktop();
            display.present();
            klog.info("Desktop: first frame presented (taskbar+shell+cursor)", .{});

            const mouse = @import("drivers/input/mouse.zig");
            var prev_buttons: u8 = 0;
            var last_draw_cx: i32 = -32768;
            var last_draw_cy: i32 = -32768;

            while (true) {
                // 先排空 8042 缓冲，减少「中断已到但队列未更新」的一帧延迟，指针更跟手。
                mouse.poll();

                var needs_ui_paint = false;
                var hover_changed = false;

                while (mouse.popEvent()) |event| {
                    const cur_buttons = event.buttons;

                    hover_changed = display.handleMouseMove(mouse.getX(), mouse.getY()) or hover_changed;

                    if (event.scroll != 0) {
                        needs_ui_paint = true;
                    }

                    if (cur_buttons != prev_buttons) {
                        if (cur_buttons & 0x01 != 0 and prev_buttons & 0x01 == 0) {
                            if (display.handleClick(mouse.getX(), mouse.getY())) needs_ui_paint = true;
                        }
                        if (cur_buttons & 0x01 == 0 and prev_buttons & 0x01 != 0) {
                            display.handleMouseRelease();
                            // 松手后必须再合成一帧，恢复任务栏毛玻璃 / 结束拖动态，否则需等指针移动才刷新。
                            needs_ui_paint = true;
                        }
                        if (cur_buttons & 0x02 != 0 and prev_buttons & 0x02 == 0) {
                            if (display.handleRightClick(mouse.getX(), mouse.getY())) needs_ui_paint = true;
                        }
                    }

                    prev_buttons = cur_buttons;
                }

                if (display.handleDesktopHotkeys()) needs_ui_paint = true;

                const mx = mouse.getX();
                const my = mouse.getY();
                const pixel_moved = (mx != last_draw_cx or my != last_draw_cy);

                // 整帧重绘：双缓冲不能只叠画光标。
                // 若启用鼠标插值，必须在「仍在插值」时继续合成，否则子步长为 0 时 pixel_moved 为假会死锁。
                const need_paint = needs_ui_paint or hover_changed or pixel_moved or
                    mouse.isInterpolating() or mouse.hasCursorMoved();

                if (need_paint) {
                    display.renderDesktopFrame();
                    display.present();
                    // 必须在 present 之后取样：renderDesktopFrame 会排空插值并更新逻辑坐标。
                    last_draw_cx = mouse.getX();
                    last_draw_cy = mouse.getY();
                } else if (mouse.hasCursorMoved()) {
                    mouse.clearCursorMoved();
                }

                mouse.poll();
                arch.waitForInterrupt();
            }
        } else {
            klog.err("Desktop: isDesktopReady=false (need multiboot framebuffer + initDesktopMode); text mode", .{});
        }
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
    klog.info("=== ZirconOS v1.0 Kernel Ready ===", .{});
    klog.info("Architecture : x86_64", .{});
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

    if (boot_mode == .powershell) {
        klog.info("=== Entering PowerShell Mode ===", .{});
        ps_mod.runInteractiveShell();
    }

    // ═══ Normal Text Mode: Demo + Shell ═══
    cmd_mod.runBootSequence();
    ps_mod.runBootSequence();
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

fn startGeneric(magic: u32, info_addr: usize) noreturn {
    const boot = arch.impl.boot;
    const frame = @import("mm/frame.zig");
    const heap = @import("mm/heap.zig");
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
    const ps_mod = @import("subsystems/win32/powershell.zig");
    const subsys = @import("subsystems/win32/subsystem.zig");
    const exec = @import("subsystems/win32/exec.zig");
    const user32_mod = @import("subsystems/win32/user32.zig");
    const gdi32_mod = @import("subsystems/win32/gdi32.zig");
    const wow64_mod = @import("subsystems/win32/wow64.zig");
    const sys_config = @import("config/config.zig");
    const audio = @import("drivers/audio/audio.zig");
    const registry = @import("registry/registry.zig");

    arch.initSerial();

    klog.info("========================================", .{});
    klog.info("  ZirconOS v1.0 (NT-style Hybrid Microkernel)", .{});
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

    const boot_info = boot.parse(magic, info_addr);
    if (boot_info) |info| {
        klog.info("Memory: upper=%u KB, mmap_entries=%u", .{
            info.mem_upper_kb, info.mmap_entry_count,
        });
        klog.info("Boot: mode=%u desktop_theme=%u (EFI handoff if magic matches)", .{
            @intFromEnum(info.boot_mode), @intFromEnum(info.desktop_theme),
        });
    }

    var alloc: frame.FrameAllocator = undefined;
    alloc.init(boot_info, 0x400000, 0);
    klog.info("Frame allocator: total_frames=%u, frame_size=%u", .{
        alloc.total_frames, frame.FRAME_SIZE,
    });

    heap.init();
    klog.info("Kernel heap: %u bytes available", .{heap.freeBytes()});

    klog.info("--- Phase 2: Scheduler + Timer ---", .{});
    scheduler.init();
    timer.init();

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
    drivers_generic.initAudioDrivers();
    vfs_mod.init();
    fat32_mod.init();
    ntfs_mod.init();

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
    ps_mod.init();

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
    klog.info("=== ZirconOS v1.0 Kernel Ready (Phase 0-12) ===", .{});
    klog.info("Architecture : %s", .{arch.impl.name});
    klog.info("Processes    : %u", .{@import("ps/process.zig").getProcessCount()});
    klog.info("Sessions     : %u", .{smss.getSessionCount()});
    klog.info("Heap         : %u/%u bytes used", .{ heap.usedBytes(), heap.totalBytes() });
    klog.info("I/O Devices  : %u, Drivers: %u", .{ io.getDeviceCount(), io.getDriverCount() });
    klog.info("", .{});

    audio.playEvent(.startup);

    cmd_mod.runBootSequence();
    ps_mod.runBootSequence();
    exec.runDemoApps();
    gdi32_mod.runGdiDemo();
    user32_mod.runGuiDemo();
    wow64_mod.runWow64Demo();

    klog.info("", .{});
    klog.info("=== System Ready ===", .{});
    klog.info("", .{});

    cmd_mod.runInteractiveShell();
}
