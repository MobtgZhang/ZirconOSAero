// SPDX-License-Identifier: MIT OR Apache-2.0
//! Desktop session: theme, framebuffer handoff, main loop, ZBM-style menu.
const std = @import("std");
const builtin = @import("builtin");
const arch = @import("../arch.zig");
const klog = @import("../rtl/klog.zig");

pub fn desktopThemeFromBuildDefault(s: []const u8) @import("../arch.zig").impl.boot.DesktopTheme {
    if (std.mem.eql(u8, s, "none")) return .none;
    return .aero;
}

pub fn desktopThemeName(theme: @import("../arch.zig").impl.boot.DesktopTheme) []const u8 {
    return switch (theme) {
        .none => "none",
        .aero => "aero",
    };
}

fn initDesktopFramebufferFromHandoff(
    binfo: *const arch.impl.boot.BootInfo,
    comptime extended_scanout_setup: bool,
) void {
    const drivers = @import("../drivers/mod.zig");
    const display = drivers.video.display;
    const user32_mod = @import("../subsystems/win32/user32.zig");

    const fb_i = binfo.fb_info orelse return;
    if (fb_i.width == 0 or fb_i.height == 0 or fb_i.bpp == 0) return;

    const use_fb = drivers.video.desktop_fb_resolve.resolveDesktopFramebuffer(.{
        .addr = fb_i.addr,
        .width = fb_i.width,
        .height = fb_i.height,
        .pitch = fb_i.pitch,
        .bpp = fb_i.bpp,
        .pixel_bgr = (fb_i.pixel_bgr != 0),
    });
    const fb_addr = @as(usize, @truncate(use_fb.addr));

    if (extended_scanout_setup) {
        if (builtin.target.cpu.arch == .loongarch64) {
            const vm = @import("../mm/vm.zig");
            const ramfb_la = @import("../hal/loongarch64/ramfb.zig");
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
            const a64r = @import("../hal/aarch64/ramfb.zig");
            if (a64r.pointRamfbToGuestPhys(use_fb.addr, use_fb.width, use_fb.height, use_fb.pitch)) {
                klog.info("ramfb(a64): QEMU scanout → guest phys 0x%x", .{@as(usize, @truncate(use_fb.addr))});
            } else if (klog.DEBUG_MODE) {
                klog.info("ramfb(a64): pointRamfbToGuestPhys skipped", .{});
            }
        }
        if (builtin.target.cpu.arch == .riscv64) {
            const rvr = @import("../hal/riscv64/ramfb.zig");
            if (rvr.pointRamfbToGuestPhys(use_fb.addr, use_fb.width, use_fb.height, use_fb.pitch)) {
                klog.info("ramfb(rv): QEMU scanout → guest phys 0x%x", .{@as(usize, @truncate(use_fb.addr))});
            } else if (klog.DEBUG_MODE) {
                klog.info("ramfb(rv): pointRamfbToGuestPhys skipped", .{});
            }
        }
        // x86_64: 当 QEMU 同时启用 -device ramfb 和固件 GOP 时,将 ramfb 扫描输出指向 GOP 物理地址,
        // 避免 QEMU GTK 窗口仍绑定到默认 ramfb 区域(0x0D000000)而 GOP 区域无像素更新导致黑屏.
        if (builtin.target.cpu.arch == .x86_64) {
            const ramfb_x86 = @import("../hal/x86_64/ramfb.zig");
            if (ramfb_x86.pointRamfbToGuestPhys(use_fb.addr, use_fb.width, use_fb.height, use_fb.pitch)) {
                klog.info("ramfb(x86_64): QEMU scanout → GOP phys 0x%x (%ux%u stride %u)", .{
                    @as(usize, @truncate(use_fb.addr)),
                    use_fb.width,
                    use_fb.height,
                    use_fb.pitch,
                });
            } else if (klog.DEBUG_MODE) {
                klog.info("ramfb(x86_64): pointRamfbToGuestPhys skipped (no etc/ramfb — OK if no -device ramfb)", .{});
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

/// 内核桌面主循环（阶段 **D-D4** 文档锚点）：每轮 `input_hub.pollAll`；`user32.msgPumpThreadsBlockedApprox` 为真时追加输入轮询以缩短 `GetMessage` 阻塞路径上的投递延迟；`idle_streak` 驱动 `display_flip_journal.extraInputPollBudget` 在空闲时仍保持尾部 `poll`；`need_paint` 为假时跳过 `present`。见 [docs/cn/PHASE_D_WIN32_MSG_PUMP_DWM.md](../docs/cn/PHASE_D_WIN32_MSG_PUMP_DWM.md)。
fn runDesktopMainLoop(comptime bisect_log_prefix: []const u8) noreturn {
    const drivers = @import("../drivers/mod.zig");
    const display = drivers.video.display;
    const video_root = @import("../drivers/video/root.zig");
    const startmenu_mod = video_root.startmenu;
    const builtin_apps_mod = video_root.builtin_apps;
    const mouse = @import("../drivers/input/mouse.zig");
    const input_hub = @import("../drivers/input/input_hub.zig");
    const mouse_debug = @import("../drivers/input/mouse_debug.zig");
    const virtio_input_pci = @import("../drivers/input/virtio_input_pci.zig");
    const display_flip_journal = video_root.display_flip_journal;
    const scheduler = @import("../ke/scheduler.zig");

    var prev_buttons: u8 = 0;
    var idle_streak: u32 = 0;
    var last_draw_cx: i32 = mouse.getX();
    var last_draw_cy: i32 = mouse.getY();
    // x86_64 及其他架构默认 16 次额外轮询; LoongArch64 在 QEMU virtio-input 路径上
    // 事件延迟可能更高,因此分配 32 次以确保输入不丢帧.
    const desktop_extra_input_polls: u32 = if (builtin.target.cpu.arch == .loongarch64) 32 else 16;

    // 每帧调用 panic_ctx.setPhase 仅在 bisect 调试模式有意义; Release 构建下 Comptime 消除以降低开销.
    const panic_ctx = @import("../rtl/panic_context.zig");
    const user32_mod = @import("../subsystems/win32/user32.zig");
    while (true) {
        // panic_ctx.setPhase 仅在 bisect 调试模式有意义; Release 构建下完全消除此函数调用开销.
        if (@import("build_options").desktop_bisect) {
            panic_ctx.setPhase(0x0001_0001);
        }
        input_hub.pollAll();
        // 阶段 D：有线程阻塞在 `GetMessage` 时额外轮询输入，降低「桌面空转、消息迟滞」概率（与 `display_flip_journal` idle 策略互补）。
        if (user32_mod.msgPumpThreadsBlockedApprox()) {
            var extra: u32 = 0;
            while (extra < 8) : (extra += 1) input_hub.pollAll();
        }
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
                display.handleDesktopScroll(event.scroll);
                needs_ui_paint = true;
            }

            if (cur_buttons != prev_buttons) {
                if (cur_buttons & 0x01 != 0 and prev_buttons & 0x01 == 0) {
                    if (display.handleClick(mouse.getX(), mouse.getY())) needs_ui_paint = true;
                }
                if (cur_buttons & 0x01 == 0 and prev_buttons & 0x01 != 0) {
                    const rel = display.handleMouseRelease();
                    if (rel.needs_full_scene) needs_ui_paint = true;
                    move_paint = display.MouseMovePaintHint.merge(move_paint, .{ .needs_post_drag_composite = rel.needs_post_drag_composite });
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
        if (display.dwm_mod.takeDesktopShellRepaintAfterDwmNotify()) needs_ui_paint = true;

        const mx = mouse.getX();
        const my = mouse.getY();
        mouse_debug.desktopHeartbeat(mx, my, virtio_input_pci.isActive(), display.isStartMenuVisible());
        const pixel_moved = (mx != last_draw_cx or my != last_draw_cy);
        const scene_dirty = needs_ui_paint or move_paint.needs_full_scene;
        const interpolating = mouse.isInterpolating();
        const startmenu_repaint = move_paint.needs_startmenu_repaint;
        const drag_repaint = move_paint.needs_drag_repaint;
        const shell_geometry_repaint = move_paint.needs_shell_frame_repaint or move_paint.needs_post_drag_composite;
        const caption_chrome_only = move_paint.needs_caption_chrome_only;
        const cursor_dirty = pixel_moved or mouse.hasCursorMoved() or move_paint.cursor_shape_changed;

        // `interpolating` 不可删：`interpolateStep` 在 `renderDesktopFrameEx` 内执行；仅靠 `pixel_moved` 会在插值中间帧漏绘。
        // 全屏重绘仅在 `display.renderDesktopFrameEx` 中 `moveOnly` 失败时回退（壳层打开时优先光标快路径）。
        const need_paint = scene_dirty or cursor_dirty or caption_chrome_only or drag_repaint or startmenu_repaint or shell_geometry_repaint or interpolating or display.isFlip3dOverlayActive();

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
                const tel = display.getDesktopComposeTelemetry();
                klog.debug("%s: post renderDesktopFrameEx pre-present ticks=%u compose_full=%u compose_partial=%u", .{
                    bisect_log_prefix,
                    @as(u32, @truncate(scheduler.getTicks() - t0)),
                    tel.full_scene_frames,
                    tel.partial_frames,
                });
            }
            // D-D4：`present()` 内 `dwm_compositor.notifyFramePresented` 与脏表面缩略刷新配对；无 `need_paint` 时跳过以免空 flip。
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

pub fn enterDesktopSession(
    alloc: *@import("../mm/frame.zig").FrameAllocator,
    boot_info_opt: ?arch.impl.boot.BootInfo,
    desktop_theme: arch.impl.boot.DesktopTheme,
    comptime extended_scanout: bool,
    comptime verbose_dwm_klog: bool,
    comptime log_dwm_session: bool,
    comptime bisect_prefix: []const u8,
    comptime not_ready_msg: []const u8,
) void {
    const drivers = @import("../drivers/mod.zig");
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

    const ps_proc = @import("../ps/process.zig");
    if (ps_proc.createSystemProcess(alloc, "dwm.exe")) |shell| {
        const ui_tid = ps_proc.allocTid() orelse 0;
        ps_proc.registerDesktopSession(shell.pid, ui_tid);
        ps_proc.setCurrentProcess(shell.pid);
        // FG-02: DWM 进程是前台进程，获得额外时间片加成
        shell.setForeground(true);
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
    // LoongArch/AArch64 + ramfb：部分 QEMU 组合在首帧像素落盘后再 point 一次 fw_cfg，主窗更易绑定到实际扫描缓冲。
    if (extended_scanout and builtin.target.cpu.arch == .loongarch64) {
        const fb_drv = drivers.video.framebuffer;
        const gaddr = fb_drv.getAddress();
        fb_drv.fenceScanoutVisibleWrites();
        const ramfb_la = @import("../hal/loongarch64/ramfb.zig");
        const gw = fb_drv.getWidth();
        const gh = fb_drv.getHeight();
        const gp = fb_drv.getPitch();
        if (gw > 0 and gh > 0 and gp > 0) {
            _ = ramfb_la.pointRamfbToGuestPhys(@as(u64, @truncate(gaddr)), gw, gh, gp);
        }
    }
    if (extended_scanout and builtin.target.cpu.arch == .aarch64) {
        const fb_drv = drivers.video.framebuffer;
        const gaddr = fb_drv.getAddress();
        fb_drv.fenceScanoutVisibleWrites();
        const a64r = @import("../hal/aarch64/ramfb.zig");
        const gw = fb_drv.getWidth();
        const gh = fb_drv.getHeight();
        const gp = fb_drv.getPitch();
        if (gw > 0 and gh > 0 and gp > 0) {
            _ = a64r.pointRamfbToGuestPhys(@as(u64, @truncate(gaddr)), gw, gh, gp);
        }
    }
    // x86_64: 首帧 ramfb 重指向 GOP 物理地址(与 LoongArch64/AArch64 相同的 extended_scanout 逻辑).
    if (extended_scanout and builtin.target.cpu.arch == .x86_64) {
        const fb_drv = drivers.video.framebuffer;
        const gaddr = fb_drv.getAddress();
        fb_drv.fenceScanoutVisibleWrites();
        const ramfb_x86 = @import("../hal/x86_64/ramfb.zig");
        const gw = fb_drv.getWidth();
        const gh = fb_drv.getHeight();
        const gp = fb_drv.getPitch();
        if (gw > 0 and gh > 0 and gp > 0) {
            _ = ramfb_x86.pointRamfbToGuestPhys(@as(u64, @truncate(gaddr)), gw, gh, gp);
        }
    }
    drivers.video.framebuffer.logFramebufferMemorySummary();
    klog.info("Desktop: first frame presented (taskbar+shell+cursor)", .{});

    @import("../drivers/input/mouse.zig").syncFromRegistry();
    display.dwm_mod.syncPolicyFromRegistry();

    runDesktopMainLoop(bisect_prefix);
}

// ── ZBM 串口菜单（与 boot/zbm/uefi/main_loongarch64.zig 样式对齐：箭头、边框、描述、ENTER/ESC）──
pub fn showZbmStyleBootMenu() void {
    const sys_config = @import("../config/config.zig");
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
            klog.info("    Architecture: %s  |  Boot: kernel direct (-kernel)", .{@tagName(builtin.target.cpu.arch)});
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
