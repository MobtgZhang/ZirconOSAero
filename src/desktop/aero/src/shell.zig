//! Aero Desktop Shell
//! Orchestrates the desktop session: initializes DWM compositor,
//! coordinates desktop, taskbar, start menu, and manages window
//! focus, z-order, session lifecycle, and theme switching.
//!
//! Startup sequence follows public Win32 shell lifecycle (session → desktop → DWM theme);
//! see docs/cn/PROCESS_NT61.md and Microsoft Learn (Window Stations and Desktops).
//! 1. WinLogon authenticates user and creates desktop
//! 2. Shell initializes resource and font loaders
//! 3. Shell initializes DWM compositor with default theme
//! 4. Desktop, taskbar, and start menu components are created
//! 5. Theme loader registers built-in themes and applies active theme
//! 6. OS interface windows (Core, CMD, .NET Shell placeholder) are minimized to taskbar
//! 7. Shell enters the desktop message loop

const theme = @import("theme.zig");
const dwm = @import("dwm");
const compositor = @import("compositor.zig");
const desktop_mod = @import("desktop.zig");
const taskbar_mod = @import("taskbar.zig");
const startmenu_mod = @import("startmenu.zig");
const gadgets_mod = @import("gadgets.zig");
const winlogon_mod = @import("winlogon.zig");
const theme_loader = @import("theme_loader.zig");
const resource_loader = @import("resource_loader.zig");
const font_loader = @import("font_loader.zig");

pub const ShellState = enum {
    initializing,
    login,
    desktop,
    lock_screen,
    shutting_down,
};

pub const OsWindowState = struct {
    title: [32]u8 = [_]u8{0} ** 32,
    title_len: u8 = 0,
    icon_id: u16 = 0,
    minimized: bool = true,
};

const MAX_OS_WINDOWS: usize = 8;
var os_windows: [MAX_OS_WINDOWS]OsWindowState = [_]OsWindowState{.{}} ** MAX_OS_WINDOWS;
var os_window_count: usize = 0;
/// 当前活动窗口索引（用于任务栏高亮同步）
var active_window_index: usize = 0;

var state: ShellState = .initializing;

pub fn getState() ShellState {
    return state;
}

fn setStr(dest: []u8, src: []const u8) u8 {
    const len = @min(src.len, dest.len);
    for (0..len) |i| {
        dest[i] = src[i];
    }
    return @intCast(len);
}

fn addOsWindow(title: []const u8, icon_id: u16) void {
    if (os_window_count >= MAX_OS_WINDOWS) return;
    var w = &os_windows[os_window_count];
    w.title_len = setStr(&w.title, title);
    w.icon_id = icon_id;
    w.minimized = true;
    os_window_count += 1;
}

pub fn initShell() void {
    resource_loader.init();
    font_loader.init();

    theme_loader.registerBuiltinThemes();

    dwm.init(.{
        .glass_enabled = true,
        .glass_opacity = theme.DwmDefaults.glass_opacity,
        .blur_radius = theme.DwmDefaults.blur_radius,
        .blur_passes = theme.DwmDefaults.blur_passes,
        .glass_saturation = theme.DwmDefaults.glass_saturation,
        .glass_tint_color = theme.DwmDefaults.glass_tint_color,
        .glass_tint_opacity = theme.DwmDefaults.glass_tint_opacity,
        .shadow_enabled = true,
        .shadow_size = theme.DwmDefaults.shadow_size,
        .shadow_layers = theme.DwmDefaults.shadow_layers,
    });

    desktop_mod.init();
    gadgets_mod.init();

    taskbar_mod.init(.{
        .glass_enabled = true,
        .height = theme.Layout.taskbar_height,
    });

    startmenu_mod.init();
    winlogon_mod.init();

    registerOsWindows();

    state = .desktop;
}

fn registerOsWindows() void {
    os_window_count = 0;
    addOsWindow("ZirconOS Core", 1);
    addOsWindow("Command Prompt", 4);
    addOsWindow(".NET Shell", 4);

    for (os_windows[0..os_window_count]) |w| {
        taskbar_mod.addTask(w.title[0..w.title_len], w.icon_id);
    }
}

pub fn getOsWindows() []const OsWindowState {
    return os_windows[0..os_window_count];
}

pub fn getOsWindowCount() usize {
    return os_window_count;
}

pub fn handleStartButton() void {
    startmenu_mod.toggle();
}

/// 更新开始按钮长按检测（每帧调用）
pub fn updateStartButtonLongPress(current_time: u32) void {
    if (taskbar_mod.updateLongPress(current_time)) {
        // 触发长按关机
        shutdown();
    }
}

/// 处理开始按钮按下
pub fn handleStartButtonDown(x: i32, y: i32, screen_h: i32, press_time: u32) void {
    if (taskbar_mod.isClickOnStartButton(x, y, screen_h)) {
        taskbar_mod.onStartButtonDown(press_time);
    }
}

/// 处理开始按钮释放
pub fn handleStartButtonUp(x: i32, y: i32, screen_h: i32) void {
    _ = x;
    _ = y;
    _ = screen_h;
    if (taskbar_mod.isStartButtonPressed()) {
        taskbar_mod.onStartButtonUp();
        // 如果菜单没有打开，打开菜单（短按行为）
        if (!startmenu_mod.isVisible()) {
            startmenu_mod.show();
        }
    }
}

pub fn handleDesktopClick(x: i32, y: i32, screen_h: i32) void {
    if (startmenu_mod.isVisible()) {
        if (!startmenu_mod.contains(screen_h, x, y)) {
            startmenu_mod.hide();
        }
        return;
    }

    // Z-order：合成器窗口 → 桌面小工具 → 任务栏 → 桌面图标（与 DWM 层叠一致）
    if (compositor.hitTestTopMost(x, y)) |surface_id| {
        // 命中窗口：根据 surface_id 查找对应的窗口并更新任务栏 active 状态
        if (findWindowIndexBySurface(surface_id)) |idx| {
            taskbar_mod.setActiveWindow(idx);
            active_window_index = idx;
        }
        return;
    }

    if (gadgets_mod.hitCpuMeter(x, y)) {
        return;
    }

    if (taskbar_mod.isClickOnStartButton(x, y, screen_h)) {
        handleStartButton();
        return;
    }

    if (taskbar_mod.isClickOnTaskbar(x, y, screen_h)) {
        return;
    }

    if (desktop_mod.iconHitTest(x, y)) |idx| {
        desktop_mod.selectIcon(idx);
        return;
    }

    desktop_mod.deselectAll();
}

/// 根据 surface_id 查找对应的窗口索引
fn findWindowIndexBySurface(surface_id: u32) ?usize {
    _ = surface_id;
    // 优先使用内核 display.zig 的键盘焦点状态（更可靠）
    // shell_keyboard_focus: 0=Explorer, 1=TaskMgr, 2=BuiltinApps
    return active_window_index;
}

/// 设置活动窗口索引（由外部窗口管理器调用）
pub fn setActiveWindow(index: usize) void {
    if (index < os_window_count) {
        active_window_index = index;
        taskbar_mod.setActiveWindow(index);
    }
}

/// 获取当前活动窗口索引
pub fn getActiveWindowIndex() usize {
    return active_window_index;
}

pub fn handleDesktopRightClick(x: i32, y: i32, screen_h: i32) void {
    _ = screen_h;
    if (startmenu_mod.isVisible()) {
        startmenu_mod.hide();
        return;
    }
    desktop_mod.showContextMenu(x, y);
}

pub fn switchTheme(cs: theme.ColorScheme) void {
    desktop_mod.applyTheme(cs);

    const sc = theme.getScheme(cs);
    dwm.updateGlassConfig(.{
        .glass_enabled = true,
        .glass_opacity = sc.glass_opacity,
        .blur_radius = theme.DwmDefaults.blur_radius,
        .blur_passes = theme.DwmDefaults.blur_passes,
        .glass_saturation = sc.glass_saturation,
        .glass_tint_color = sc.glass_tint,
        .glass_tint_opacity = sc.glass_tint_opacity,
        .shadow_enabled = true,
        .shadow_size = theme.DwmDefaults.shadow_size,
        .shadow_layers = theme.DwmDefaults.shadow_layers,
    });
}

pub fn switchThemeByName(name: []const u8) bool {
    if (theme_loader.findThemeById(name)) |tc| {
        theme_loader.applyThemeConfig(tc);
        switchTheme(tc.color_scheme);
        return true;
    }
    return false;
}

pub fn getAvailableThemeCount() usize {
    return theme_loader.getThemeCount();
}

pub fn lockDesktop() void {
    state = .lock_screen;
    winlogon_mod.lockSession();
}

pub fn shutdown() void {
    state = .shutting_down;
}
