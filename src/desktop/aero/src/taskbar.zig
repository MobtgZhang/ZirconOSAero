//! Aero Taskbar
//! Start orb, quick launch, task buttons, notification area (tray),
//! stacked clock (time + date), and Aero Peek show-desktop strip.
//! 任务栏缩略图 / 实时预览应对接合成器离屏表面（DWM 缩略图概念），见 `compositor` 与 `docs/cn/DesktopManagerSpec.md`。

const theme = @import("theme.zig");

pub const HitRect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

pub const TaskbarConfig = struct {
    glass_enabled: bool = true,
    height: i32 = theme.Layout.taskbar_height,
};

pub const TaskButton = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,
    icon_id: u16 = 0,
    active: bool = false,
    flashing: bool = false,
};

const MAX_TASK_BUTTONS: usize = 32;
var buttons: [MAX_TASK_BUTTONS]TaskButton = [_]TaskButton{.{}} ** MAX_TASK_BUTTONS;
var button_count: usize = 0;
var cfg: TaskbarConfig = .{};
var initialized_flag: bool = false;
/// Shell / 合成器可查询：用户按住 Show Desktop 条时的 Aero Peek 预览态（阶段 2 Shell 占位）。
var aero_peek_active: bool = false;

pub fn setAeroPeekActive(active: bool) void {
    aero_peek_active = active;
}

pub fn isAeroPeekActive() bool {
    return aero_peek_active;
}

pub fn init(config: TaskbarConfig) void {
    cfg = config;
    button_count = 0;
    initialized_flag = true;
}

pub fn getHeight() i32 {
    return cfg.height;
}

pub fn isGlassEnabled() bool {
    return cfg.glass_enabled;
}

pub fn addTask(name: []const u8, icon_id: u16) void {
    if (button_count >= MAX_TASK_BUTTONS) return;
    var btn = &buttons[button_count];
    const len = @min(name.len, 32);
    for (0..len) |i| {
        btn.name[i] = name[i];
    }
    btn.name_len = @intCast(len);
    btn.icon_id = icon_id;
    button_count += 1;
}

pub fn setActive(icon_id: u16) void {
    for (buttons[0..button_count]) |*btn| {
        btn.active = (btn.icon_id == icon_id);
    }
}

pub fn getButtons() []const TaskButton {
    return buttons[0..button_count];
}

pub fn isClickOnStartButton(x: i32, y: i32, screen_h: i32) bool {
    const tb_y = screen_h - cfg.height;
    if (y < tb_y or y >= screen_h) return false;
    const slot_w = theme.Layout.start_btn_width;
    const r = @divTrunc(theme.Layout.start_btn_orb_size, 2);
    const cx = @divTrunc(slot_w, 2);
    const cy = tb_y + @divTrunc(cfg.height, 2);
    const dx = x - cx;
    const dy = y - cy;
    const hit_r = r + 2;
    return dx * dx + dy * dy <= hit_r * hit_r;
}

pub fn isClickOnTaskbar(x: i32, y: i32, screen_h: i32) bool {
    _ = x;
    const tb_y = screen_h - cfg.height;
    return y >= tb_y and y < screen_h;
}

pub fn getGlassTint() u32 {
    return theme.taskbar_glass_tint;
}

pub fn getGlassOpacity() u8 {
    return theme.taskbar_glass_opacity;
}

/// 命中 Show Desktop / Peek 竖条（含右缘 inclusive 边界）。
pub fn isClickOnShowDesktopPeek(x: i32, y: i32, screen_w: i32, screen_h: i32) bool {
    const r = getShowDesktopButtonRect(screen_w, screen_h);
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

/// Far-right vertical strip used for Show Desktop / Aero Peek hit testing.
pub fn getShowDesktopButtonRect(screen_w: i32, screen_h: i32) HitRect {
    const tb_h = cfg.height;
    const peek_w = theme.Layout.show_desktop_peek_width;
    return .{
        .x = screen_w - peek_w,
        .y = screen_h - tb_h,
        .w = peek_w,
        .h = tb_h,
    };
}

/// Typical Win7 tray: network, volume, action center, clock, hidden-icons chevron.
pub const tray_notification_slot_count: usize = 6;
