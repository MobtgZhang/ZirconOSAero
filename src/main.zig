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
extern const _kernel_end: u8;

/// agent_ndjson：桌面循环心跳序号（x86 / generic 二选一，同映像共用）
var agent_desktop_h4_tick: u32 = 0;

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
    alloc.init(boot_info, kernel_end);
    frame.setKernelFrameAllocator(&alloc);
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
    vm.bindKernelAddressSpace(&kernel_space);
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
                    const use_fb = drivers.video.desktop_fb_resolve.resolveDesktopFramebuffer(.{
                        .addr = fb_i.addr,
                        .width = fb_i.width,
                        .height = fb_i.height,
                        .pitch = fb_i.pitch,
                        .bpp = fb_i.bpp,
                        .pixel_bgr = fb_i.pixel_bgr != 0,
                    });
                    const fb_addr = @as(usize, @truncate(use_fb.addr));

                    if (!arch.impl.framebuffer.isReady()) {
                        arch.initFramebuffer(fb_addr, use_fb.width, use_fb.height, use_fb.pitch, use_fb.bpp);
                    }
                    arch.impl.framebuffer.setConsoleEnabled(false);

                    drivers.initDesktopMode(fb_addr, use_fb.width, use_fb.height, use_fb.pitch, use_fb.bpp, use_fb.pixel_bgr);
                    user32_mod.syncScreenFromFramebuffer();
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
            drivers.video.framebuffer.logFramebufferMemorySummary();
            klog.info("Desktop: first frame presented (taskbar+shell+cursor)", .{});

            const mouse = @import("drivers/input/mouse.zig");
            const input_hub = @import("drivers/input/input_hub.zig");
            const mouse_debug = @import("drivers/input/mouse_debug.zig");
            const virtio_input_pci = @import("drivers/input/virtio_input_pci.zig");
            var prev_buttons: u8 = 0;
            // 与当前逻辑坐标对齐，否则 (0,0) 与初值 -32768 比较会误判「指针移动」，
            // 在首次 present 后立即再画一整帧（第二帧关闭毛玻璃盒式模糊快速路径，易触发重负载路径）。
            var last_draw_cx: i32 = mouse.getX();
            var last_draw_cy: i32 = mouse.getY();

            while (true) {
                // VirtIO-Input PCI + PS/2 8042 一并排空（QEMU 可加 `-device virtio-mouse-pci`）
                input_hub.pollAll();
                const nudge = arch.takeCursorNudge();
                if (nudge.dx != 0 or nudge.dy != 0) mouse.injectNudge(nudge.dx, nudge.dy);

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

                // 再排空一轮：避免 IRQ 在 pop 循环与取样之间写入的包直到下一 tick 才被读。
                input_hub.pollAll();
                hover_changed = display.handleMouseMove(mouse.getX(), mouse.getY()) or hover_changed;

                if (display.handleDesktopHotkeys()) needs_ui_paint = true;

                const mx = mouse.getX();
                const my = mouse.getY();
                mouse_debug.desktopHeartbeat(mx, my, virtio_input_pci.isActive());
                // #region agent log
                if (@import("build_options").agent_ndjson) {
                    agent_desktop_h4_tick +%= 1;
                    if (agent_desktop_h4_tick % 72 == 0) {
                        const ag = @import("debug/agent_ndjson.zig");
                        ag.emit("H4", "main.zig:desktop", "heartbeat", "pre", @intFromBool(virtio_input_pci.isActive()), @as(u64, @intCast(agent_desktop_h4_tick)), 0, 0, mx, my);
                    }
                }
                // #endregion
                const pixel_moved = (mx != last_draw_cx or my != last_draw_cy);
                const queued = mouse.hasEvents();
                const scene_dirty = needs_ui_paint or hover_changed or queued or mouse.isInterpolating();
                const cursor_dirty = pixel_moved or mouse.hasCursorMoved();

                // 整帧重绘：双缓冲不能只叠画光标。
                // 若启用鼠标插值，必须在「仍在插值」时继续合成，否则子步长为 0 时 pixel_moved 为假会死锁。
                const need_paint = scene_dirty or cursor_dirty;

                if (need_paint) {
                    if (@import("build_options").desktop_bisect) {
                        klog.debug("desktop: pre renderDesktopFrameEx scene_dirty=%u", .{@intFromBool(scene_dirty)});
                    }
                    display.renderDesktopFrameEx(scene_dirty);
                    if (@import("build_options").desktop_bisect) {
                        klog.debug("desktop: post renderDesktopFrameEx pre-present", .{});
                    }
                    display.present();
                    // 必须在 present 之后取样：renderDesktopFrame 会排空插值并更新逻辑坐标。
                    last_draw_cx = mouse.getX();
                    last_draw_cy = mouse.getY();
                } else if (mouse.hasCursorMoved()) {
                    mouse.clearCursorMoved();
                }

                for (0..16) |_| input_hub.pollAll();
                arch.waitForInterruptDesktop();
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
        "Start ZirconOS normally.",
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
            klog.info("                    ZirconOS Boot Manager                                     ", .{});
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
    const drivers = @import("drivers/mod.zig");
    const display = drivers.video.display;
    const vm = @import("mm/vm.zig");
    var loong_kernel_space: ?vm.AddressSpace = null;
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

    var boot_info = boot.parse(magic, info_addr);

    var alloc: frame.FrameAllocator = undefined;
    // LoongArch：尽早初始化 alloc + VM，map 2GB 以覆盖 GOP framebuffer（可能 >512MB）
    if (builtin.target.cpu.arch == .loongarch64) {
        // QEMU GTK 往往只扫「固件 GOP」窗口；若 ZBM 已将 GOP SetMode 到 ≥1024×768，handoff 与该窗口同源，应直接使用。
        // 否则丢弃过小/非线性 GOP，由 ramfb.setup() 写 0xF000000（部分 QEMU 配置下窗口仍不跟 ramfb，见文档）。
        if (boot_info) |bi_in| {
            var bi_mut = bi_in;
            const gop_ok = if (bi_mut.fb_info) |fb|
                (fb.width >= 1024 and fb.height >= 768 and fb.addr != 0 and fb.bpp == 32)
            else
                false;
            if (!gop_ok) {
                if (bi_mut.fb_info != null) {
                    klog.info("Display: GOP handoff not ≥1024x768; using ramfb @ RAMFB_PHYS", .{});
                }
                bi_mut.fb_info = null;
            } else {
                klog.info("Display: using UEFI GOP %ux%u (same as QEMU primary scanout)", .{
                    bi_mut.fb_info.?.width, bi_mut.fb_info.?.height,
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
        const paging = arch.impl.paging;
        if (vm.createAddressSpace(&alloc)) |ks| {
            loong_kernel_space = ks;
            const kernel_space = &loong_kernel_space.?;
            // 0–2GiB：GOP/ramfb；GPU MMIO 若落在 2–4GiB，`vm.mapDeviceMmioIdentity` 会按需建 identity 非缓存映射
            const identity_pages: usize = (2 * 1024 * 1024 * 1024) / paging.page_size;
            const id_limit: usize = identity_pages * paging.page_size;
            var i: usize = 0;
            while (i < identity_pages) : (i += 1) {
                const virt = i * paging.page_size;
                const flags = vm.MapFlags{ .writable = true, .executable = true };
                if (!kernel_space.mapPage(virt, virt, flags)) {
                    klog.err("LoongArch: identity map failed at 0x%x (check UEFI mmap / frame pool)", .{virt});
                    arch.halt();
                }
            }
            // virtio-gpu / 部分固件 GOP 帧缓冲落在 PCI BAR（物理地址 ≥2GiB）；仅 map 低 2GiB 时访问桌面会缺页
            if (boot_info) |binfo| {
                if (binfo.fb_info) |fb_i| {
                    if (fb_i.addr != 0 and fb_i.height > 0 and fb_i.pitch > 0) {
                        const fb_base = @as(usize, @truncate(fb_i.addr)) & ~@as(usize, paging.page_size - 1);
                        const fb_bytes = @as(usize, fb_i.pitch) * @as(usize, fb_i.height);
                        if (fb_bytes != 0) {
                            const fb_end = fb_base + fb_bytes;
                            const va_limit = (fb_end + paging.page_size - 1) & ~@as(usize, paging.page_size - 1);
                            var va = fb_base;
                            while (va < va_limit) : (va += paging.page_size) {
                                if (va >= id_limit) {
                                    const fb_flags = vm.MapFlags{ .writable = true, .executable = false, .no_cache = true };
                                    if (!kernel_space.mapPage(va, va, fb_flags)) {
                                        klog.err("LoongArch: framebuffer map failed at 0x%x (past 2GiB)", .{va});
                                        arch.halt();
                                    }
                                }
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
        const ramfb = @import("hal/loongarch64/ramfb.zig");
        const has_gop_fb = if (boot_info) |b| (b.fb_info != null and b.fb_info.?.addr != 0) else false;
        if (!has_gop_fb) {
            if (ramfb.setup()) |fb_i| {
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
                klog.info("ramfb: %ux%u@%u addr=0x%x", .{
                    fb_i.width, fb_i.height, fb_i.bpp,
                    @as(usize, @truncate(fb_i.addr)),
                });
            } else {
                klog.warn("ramfb: setup failed, no framebuffer", .{});
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
        const k_reserved = ( @intFromPtr(&_kernel_end) + 4095 ) & ~@as(usize, 4095);
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
            var ip: usize = 0;
            while (ip < npg) : (ip += 1) {
                const v = ip * paging.page_size;
                _ = ksp.mapPage(v, v, .{ .writable = true, .executable = true });
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
            ksp.activate();
            vm.bindKernelAddressSpace(ksp);
            klog.info("VM: RISC-V64 identity map low 2GiB + RAM@0x80000000 (512MiB)", .{});
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

    heap.init();
    klog.info("Kernel heap: %u bytes available", .{heap.freeBytes()});

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
        klog.info("Desktop: Preparing %s theme...", .{desktopThemeName(desktop_theme)});
        arch.impl.framebuffer.setConsoleEnabled(false);
        if (boot_info) |binfo| {
            if (binfo.fb_info) |fb_i| {
                if (fb_i.width > 0 and fb_i.height > 0 and fb_i.bpp > 0) {
                    const use_fb = drivers.video.desktop_fb_resolve.resolveDesktopFramebuffer(.{
                        .addr = fb_i.addr,
                        .width = fb_i.width,
                        .height = fb_i.height,
                        .pitch = fb_i.pitch,
                        .bpp = fb_i.bpp,
                        .pixel_bgr = if (builtin.target.cpu.arch == .x86_64) (fb_i.pixel_bgr != 0) else true,
                    });
                    const fb_addr = @as(usize, @truncate(use_fb.addr));
                    if (builtin.target.cpu.arch == .loongarch64) {
                        const fb_bytes = @as(usize, use_fb.pitch) * @as(usize, use_fb.height);
                        if (vm.remapIdentityRangeUncached(fb_addr, fb_bytes)) {
                            klog.info("VM: LoongArch scanout FB 0x%x size 0x%x → uncached (GOP/ramfb visible)", .{
                                fb_addr, fb_bytes,
                            });
                        } else {
                            klog.warn("VM: LoongArch framebuffer uncached remap failed — desktop may not scan out", .{});
                        }
                        const ramfb = @import("hal/loongarch64/ramfb.zig");
                        if (ramfb.pointRamfbToGuestPhys(
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
                        // 勿对 ramfb/GOP RAM 调用 `remapIdentityRangeUncached`：AArch64 上 `no_cache` 当前映射为
                        // PTE AttrIdx=1，而内核未编程 MAIR_EL1；固件下索引 1 多为 Device 内存，对 RAM 做 memcpy 会 Data Abort。
                        // 保持 Phase 1 identity 映射的 Normal WB 即可；QEMU ramfb 区域仍为常规 DRAM。
                        const a64r = @import("hal/aarch64/ramfb.zig");
                        if (a64r.pointRamfbToGuestPhys(use_fb.addr, use_fb.width, use_fb.height, use_fb.pitch)) {
                            klog.info("ramfb(a64): QEMU scanout → guest phys 0x%x", .{@as(usize, @truncate(use_fb.addr))});
                        } else if (klog.DEBUG_MODE) {
                            klog.info("ramfb(a64): pointRamfbToGuestPhys skipped", .{});
                        }
                    }
                    if (!arch.impl.framebuffer.isReady()) {
                        arch.initFramebuffer(fb_addr, use_fb.width, use_fb.height, use_fb.pitch, use_fb.bpp);
                    }
                    arch.impl.framebuffer.setConsoleEnabled(false);
                    // LoongArch ramfb / UEFI GOP：线性缓冲通常为 BGRx；x86 Multiboot 用元数据 pixel_bgr
                    drivers.initDesktopMode(fb_addr, use_fb.width, use_fb.height, use_fb.pitch, use_fb.bpp, use_fb.pixel_bgr);
                    user32_mod.syncScreenFromFramebuffer();
                    display.syncCursorFromMouse();
                    display.clearFramebuffer();
                }
            }
        }
        display.setTheme(.aero);
        display.initAeroDwm();
        klog.info("Desktop: DWM Aero compositor initialized", .{});
        if (drivers.isDesktopReady()) {
            klog.info("Desktop: Rendering %s theme", .{desktopThemeName(desktop_theme)});
            const ps_proc = @import("ps/process.zig");
            if (ps_proc.createSystemProcess(&alloc, "dwm.exe")) |shell| {
                const ui_tid = ps_proc.allocTid() orelse 0;
                ps_proc.registerDesktopSession(shell.pid, ui_tid);
                ps_proc.setCurrentProcess(shell.pid);
            }
            display.renderAeroDesktop();
            display.present();
            drivers.video.framebuffer.logFramebufferMemorySummary();
            const mouse = @import("drivers/input/mouse.zig");
            const input_hub = @import("drivers/input/input_hub.zig");
            const mouse_debug = @import("drivers/input/mouse_debug.zig");
            const virtio_input_pci = @import("drivers/input/virtio_input_pci.zig");
            var prev_buttons: u8 = 0;
            var last_draw_cx: i32 = mouse.getX();
            var last_draw_cy: i32 = mouse.getY();
            while (true) {
                input_hub.pollAll();
                const nudge2 = arch.takeCursorNudge();
                if (nudge2.dx != 0 or nudge2.dy != 0) mouse.injectNudge(nudge2.dx, nudge2.dy);
                var needs_ui_paint = false;
                var hover_changed = false;
                while (mouse.popEvent()) |event| {
                    const cur_buttons = event.buttons;
                    hover_changed = display.handleMouseMove(mouse.getX(), mouse.getY()) or hover_changed;
                    if (event.scroll != 0) needs_ui_paint = true;
                    if (cur_buttons != prev_buttons) {
                        if (cur_buttons & 0x01 != 0 and prev_buttons & 0x01 == 0) {
                            if (display.handleClick(mouse.getX(), mouse.getY())) needs_ui_paint = true;
                        }
                        if (cur_buttons & 0x01 == 0 and prev_buttons & 0x01 != 0) {
                            display.handleMouseRelease();
                            needs_ui_paint = true;
                        }
                        if (cur_buttons & 0x02 != 0 and prev_buttons & 0x02 == 0) {
                            if (display.handleRightClick(mouse.getX(), mouse.getY())) needs_ui_paint = true;
                        }
                    }
                    prev_buttons = cur_buttons;
                }
                input_hub.pollAll();
                hover_changed = display.handleMouseMove(mouse.getX(), mouse.getY()) or hover_changed;
                if (display.handleDesktopHotkeys()) needs_ui_paint = true;
                const mx = mouse.getX();
                const my = mouse.getY();
                mouse_debug.desktopHeartbeat(mx, my, virtio_input_pci.isActive());
                // #region agent log
                if (@import("build_options").agent_ndjson) {
                    agent_desktop_h4_tick +%= 1;
                    if (agent_desktop_h4_tick % 72 == 0) {
                        const ag = @import("debug/agent_ndjson.zig");
                        ag.emit("H4", "main.zig:desktop_generic", "heartbeat", "pre", @intFromBool(virtio_input_pci.isActive()), @as(u64, @intCast(agent_desktop_h4_tick)), 0, 0, mx, my);
                    }
                }
                // #endregion
                const pixel_moved = (mx != last_draw_cx or my != last_draw_cy);
                const queued = mouse.hasEvents();
                const scene_dirty = needs_ui_paint or hover_changed or queued or mouse.isInterpolating();
                const cursor_dirty = pixel_moved or mouse.hasCursorMoved();
                const need_paint = scene_dirty or cursor_dirty;
                if (need_paint) {
                    if (@import("build_options").desktop_bisect) {
                        klog.debug("desktop_generic: pre renderDesktopFrameEx scene_dirty=%u", .{@intFromBool(scene_dirty)});
                    }
                    display.renderDesktopFrameEx(scene_dirty);
                    if (@import("build_options").desktop_bisect) {
                        klog.debug("desktop_generic: post renderDesktopFrameEx pre-present", .{});
                    }
                    display.present();
                    last_draw_cx = mouse.getX();
                    last_draw_cy = mouse.getY();
                } else if (mouse.hasCursorMoved()) {
                    mouse.clearCursorMoved();
                }
                for (0..16) |_| input_hub.pollAll();
                arch.waitForInterruptDesktop();
            }
        } else {
            klog.err("Desktop: isDesktopReady=false", .{});
        }
    }

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
