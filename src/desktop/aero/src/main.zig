//! ZirconOS Aero Desktop — DWM Compositor Entry Point
//!
//! Implements the Windows 7 DWM architecture from win7Desktop.md:
//!   1. Each window renders to its own Redirected Surface (off-screen buffer)
//!   2. DWM compositor reads all surfaces and alpha-blends by Z-order
//!   3. Glass effect: multi-pass box blur → desaturate/tint → specular highlight
//!   4. VSync-aligned frame presentation
//!
//! Resources: 本目录下 `resources/`（壁纸、图标等）
//! Fonts: `src/fonts/`（全主题共享）
//!
//! The kernel (ZirconOS/src) provides only minimal OS interfaces:
//!   - Minimized Core window (kernel services status)
//!   - Minimized CMD window (command prompt)
//!   - Minimized PowerShell window

const std = @import("std");
const root = @import("root.zig");
const theme = root.theme;
const dwm = root.dwm;
const shell = root.shell;
const desktop = root.desktop;
const taskbar = root.taskbar;
const startmenu = root.startmenu;
const gadgets = root.gadgets;
const compositor = @import("compositor.zig");
const resource_loader = @import("resource_loader.zig");
const font_loader = @import("font_loader.zig");

const SCREEN_W: u32 = 1024;
const SCREEN_H: u32 = 768;

const OsWindow = struct {
    title: []const u8,
    icon_id: u16,
    minimized: bool,
};

const os_windows = [_]OsWindow{
    .{ .title = "ZirconOS Core", .icon_id = 1, .minimized = true },
    .{ .title = "Command Prompt", .icon_id = 4, .minimized = true },
    .{ .title = "PowerShell", .icon_id = 4, .minimized = true },
};

fn p(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    out.print(fmt, args) catch {};
}

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;

    p(out, "╔══════════════════════════════════════════╗\n", .{});
    p(out, "║  ZirconOS {s} v{s}                      ║\n", .{ root.theme_name, root.theme_version });
    p(out, "║  DWM Desktop Window Manager              ║\n", .{});
    p(out, "╚══════════════════════════════════════════╝\n\n", .{});

    // ── Phase 1: Load Resources ──
    p(out, "--- Phase 1: Loading Resources ---\n", .{});

    resource_loader.init();
    p(out, "  Wallpapers : {d} loaded\n", .{resource_loader.getWallpaperCount()});
    p(out, "  Icons      : {d} loaded\n", .{resource_loader.getIconCount()});
    p(out, "  Cursors    : {d} loaded\n", .{resource_loader.getCursorCount()});
    p(out, "  Themes     : {d} loaded\n", .{resource_loader.getThemeFileCount()});

    // ── Phase 2: Load Fonts ──
    p(out, "\n--- Phase 2: Loading Fonts ---\n", .{});

    font_loader.init();
    p(out, "  Western fonts : {d} families\n", .{font_loader.getWesternFontCount()});
    p(out, "  CJK fonts     : {d} families\n", .{font_loader.getCjkFontCount()});
    p(out, "  System font   : {s}\n", .{font_loader.getSystemFontName()});
    p(out, "  Mono font     : {s}\n", .{font_loader.getMonoFontName()});
    p(out, "  CJK font      : {s}\n", .{font_loader.getCjkFontName()});

    // ── Phase 3: Initialize DWM Compositor ──
    // Architecture per win7Desktop.md:
    //   dwm.exe runs in user mode, uses Direct3D 9 for GPU-accelerated compositing
    //   Each window paints to a Redirected Surface (independent GPU texture)
    //   Compositor reads all textures, blends by Z-order with glass effects
    p(out, "\n--- Phase 3: DWM Compositor Init ---\n", .{});

    shell.initShell();
    compositor.init(SCREEN_W, SCREEN_H);

    p(out, "  DWM enabled    : {}\n", .{root.isDwmEnabled()});
    p(out, "  Glass tint     : 0x{X:0>6}\n", .{root.getGlassTintColor()});
    p(out, "  Glass opacity  : {d}\n", .{root.getGlassOpacity()});
    p(out, "  Blur radius    : {d}\n", .{dwm.getConfig().blur_radius});
    p(out, "  Blur passes    : {d} (approximates Gaussian)\n", .{dwm.getConfig().blur_passes});
    p(out, "  Shadow layers  : {d}\n", .{dwm.getConfig().shadow_layers});
    p(out, "  Screen size    : {d}x{d}\n", .{ SCREEN_W, SCREEN_H });

    // ── Phase 4: Create Redirected Surfaces ──
    p(out, "\n--- Phase 4: Creating Redirected Surfaces ---\n", .{});

    const desktop_surface = compositor.createSurface(SCREEN_W, SCREEN_H, .{
        .has_alpha = false,
        .is_visible = true,
        .is_desktop = true,
    });
    compositor.setSurfaceZOrder(desktop_surface, compositor.DESKTOP_SURFACE_Z);
    p(out, "  Desktop surface   : id={d}\n", .{desktop_surface});

    const window_surface = compositor.createSurface(520, 380, .{
        .has_alpha = true,
        .needs_shadow = true,
        .is_visible = true,
        .is_glass = true,
        .needs_blur = true,
    });
    compositor.moveSurface(window_surface, 200, 80);
    compositor.setSurfaceZOrder(window_surface, 100);
    p(out, "  Window surface    : id={d} (Computer - glass+shadow)\n", .{window_surface});

    const taskbar_surface = compositor.createSurface(SCREEN_W, 40, .{
        .has_alpha = true,
        .is_visible = true,
        .is_glass = true,
        .needs_blur = true,
    });
    compositor.moveSurface(taskbar_surface, 0, @intCast(SCREEN_H - 40));
    compositor.setSurfaceZOrder(taskbar_surface, 200);
    p(out, "  Taskbar surface   : id={d} (glass)\n", .{taskbar_surface});

    for (os_windows, 0..) |win, i| {
        taskbar.addTask(win.title, win.icon_id);
        p(out, "  OS Window [{d}]     : \"{s}\" (minimized to taskbar)\n", .{ i, win.title });
    }

    p(out, "  Total surfaces    : {d}\n", .{compositor.getSurfaceCount()});

    // ── Phase 5: Render Desktop Frame ──
    // DWM composition pipeline (from win7Desktop.md):
    //   1. Sort surfaces by Z-order
    //   2. Glass: blur background → desaturate → tint blend → specular highlight
    //   3. Shadow: multi-layer soft drop shadow
    //   4. Alpha-blend onto front buffer → VSync present
    p(out, "\n--- Phase 5: DWM Composition ---\n", .{});

    compositor.compose();
    const stats = compositor.getStats();

    p(out, "  Total frames      : {d}\n", .{stats.total_frames});
    p(out, "  Dirty frames      : {d}\n", .{stats.dirty_frames});
    p(out, "  Surfaces composited: {d}\n", .{stats.surfaces_composited});
    p(out, "  Glass surfaces    : {d}\n", .{stats.glass_surfaces});

    // ── Phase 6: Desktop Layout Report ──
    p(out, "\n--- Phase 6: Desktop Layout ---\n", .{});

    p(out, "  Wallpaper          : {s}\n", .{root.getWallpaperPath()});
    p(out, "  Desktop background : 0x{X:0>6}\n", .{root.getDesktopBackground()});
    p(out, "  Desktop icons      : {d}\n", .{desktop.getIconCount()});
    for (desktop.getIcons()) |icon| {
        if (icon.visible) {
            const sfx: []const u8 = if (icon.shortcut) " [shortcut]" else "";
            p(out, "    [{d},{d}] {s}{s}\n", .{
                icon.grid_x, icon.grid_y, icon.name[0..icon.name_len], sfx,
            });
        }
    }

    p(out, "  Taskbar height     : {d}px\n", .{root.getTaskbarHeight()});
    p(out, "  Titlebar height    : {d}px\n", .{root.getTitlebarHeight()});
    p(out, "  Start menu         : visible={}\n", .{startmenu.isVisible()});

    gadgets.tickDemo(stats.total_frames);
    const gm = gadgets.getCpuMeter();
    p(out, "  Desktop gadget     : CPU ~{d}%  {s}  @({d},{d}) r={d}\n", .{
        gm.cpu_percent,
        gm.net_kbps_str[0..gm.net_kbps_len],
        gm.center_x,
        gm.center_y,
        gm.radius,
    });

    // ── Phase 7: Theme Variants ──
    p(out, "\n--- Phase 7: Available Themes ({d}) ---\n", .{root.getAvailableThemeCount()});
    for (root.available_themes, 0..) |name, i| {
        const marker: []const u8 = if (i == 0) " [active]" else "";
        p(out, "  [{d}] {s}{s}\n", .{ i, name, marker });
    }

    // ── Phase 8: DWM Rendering Pipeline Summary ──
    p(out, "\n--- DWM Rendering Pipeline (win7Desktop.md) ---\n", .{});
    p(out, "  ┌─────────────────────────────────────────┐\n", .{});
    p(out, "  │ Application → Redirected Surface        │\n", .{});
    p(out, "  │         (each window has its own)       │\n", .{});
    p(out, "  ├─────────────────────────────────────────┤\n", .{});
    p(out, "  │ DWM Compositor reads all surfaces       │\n", .{});
    p(out, "  │   ├─ Sort by Z-order                    │\n", .{});
    p(out, "  │   ├─ Box blur (3 passes ≈ Gaussian)     │\n", .{});
    p(out, "  │   ├─ Desaturate + tint alpha blend      │\n", .{});
    p(out, "  │   ├─ Specular highlight band            │\n", .{});
    p(out, "  │   └─ Soft multi-layer drop shadow       │\n", .{});
    p(out, "  ├─────────────────────────────────────────┤\n", .{});
    p(out, "  │ VSync-aligned present → Front Buffer    │\n", .{});
    p(out, "  └─────────────────────────────────────────┘\n", .{});

    // ── Phase 9: Font Integration Summary ──
    p(out, "\n--- Font Integration (ZirconOSFonts) ---\n", .{});
    p(out, "  System UI    : {s} ({d}pt)\n", .{ font_loader.getSystemFontName(), theme.FONT_SYSTEM_SIZE });
    p(out, "  Terminal     : {s} ({d}pt)\n", .{ font_loader.getMonoFontName(), theme.FONT_MONO_SIZE });
    p(out, "  CJK Fallback : {s}\n", .{font_loader.getCjkFontName()});
    p(out, "  Title font   : {s} Bold\n", .{font_loader.getSystemFontName()});

    // ── Phase 10: Resource Integration Summary ──
    p(out, "\n--- Resource Integration (ZirconOSAero/resources) ---\n", .{});
    p(out, "  Start orb    : resources/start_orb.svg\n", .{});
    p(out, "  Logo         : resources/logo.svg\n", .{});
    p(out, "  Cursor       : resources/cursors/zircon_arrow.svg\n", .{});

    for (resource_loader.getLoadedIcons()) |icon| {
        if (icon.loaded) {
            p(out, "  Icon         : {s}\n", .{icon.path[0..icon.path_len]});
        }
    }

    p(out, "\n═══ Aero Desktop Ready ═══\n", .{});
    p(out, "DWM compositor running with {d} surfaces, glass={}, smooth_cursor=true\n", .{
        compositor.getSurfaceCount(),
        root.isDwmEnabled(),
    });
    p(out, "OS windows minimized to taskbar: ", .{});
    for (os_windows, 0..) |win, i| {
        if (i > 0) p(out, ", ", .{});
        p(out, "{s}", .{win.title});
    }
    p(out, "\n", .{});

    out.flush() catch {};
}
