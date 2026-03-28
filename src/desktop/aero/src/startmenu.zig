//! Windows 7-style Start Menu (host Aero library).
//! Two-column layout: left column has pinned programs and all-programs
//! link, right column has libraries and system links.
//! Glass border, search box at bottom, user header.

const theme = @import("theme.zig");

pub const MenuItem = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,
    icon_id: u16 = 0,
    is_separator: bool = false,
    is_system_link: bool = false,
};

const MAX_LEFT_ITEMS: usize = 16;
const MAX_RIGHT_ITEMS: usize = 16;

var left_items: [MAX_LEFT_ITEMS]MenuItem = [_]MenuItem{.{}} ** MAX_LEFT_ITEMS;
var left_count: usize = 0;

var right_items: [MAX_RIGHT_ITEMS]MenuItem = [_]MenuItem{.{}} ** MAX_RIGHT_ITEMS;
var right_count: usize = 0;

var visible: bool = false;
var search_text: [128]u8 = [_]u8{0} ** 128;
var search_len: usize = 0;

pub fn init() void {
    left_count = 0;
    right_count = 0;
    visible = false;
    search_len = 0;

    addDefaultItems();
}

fn setStr(dest: []u8, src: []const u8) u8 {
    const len = @min(src.len, dest.len);
    for (0..len) |i| {
        dest[i] = src[i];
    }
    return @intCast(len);
}

fn addLeft(name: []const u8, icon_id: u16) void {
    if (left_count >= MAX_LEFT_ITEMS) return;
    var item = &left_items[left_count];
    item.name_len = setStr(&item.name, name);
    item.icon_id = icon_id;
    left_count += 1;
}

fn addRight(name: []const u8, icon_id: u16) void {
    if (right_count >= MAX_RIGHT_ITEMS) return;
    var item = &right_items[right_count];
    item.name_len = setStr(&item.name, name);
    item.icon_id = icon_id;
    item.is_system_link = true;
    right_count += 1;
}

pub const identity = struct {
    pub const title = "Start Menu";
    pub const search_placeholder = "Search programs and files";
    pub const header_sub = "Standard user";
    pub const shutdown_label = "Shut down";
    pub const logoff_label = "Log off";
    pub const user_name = "User";
    /// Reserved for future build stamp; keep empty so shells do not show marketing text.
    pub const version_tag = "";
    /// Optional zh-CN labels for host shells that localize the start menu
    pub const zh_title = "「开始」菜单";
    pub const zh_search = "搜索程序和文件";
};

pub const identity_zh = struct {
    pub const taskbar_props = "任务栏和「开始」菜单属性";
    pub const tab_taskbar = "任务栏";
    pub const tab_start_menu = "「开始」菜单";
    pub const tab_toolbars = "工具栏";
};

fn addDefaultItems() void {
    addLeft("Internet Explorer", 6);
    addLeft("Zircon Media Player", 11);
    addLeft("Terminal", 4);
    addLeft("PowerShell", 4);
    addLeft("Notepad", 9);
    addLeft("Calculator", 8);
    addLeft("Paint", 10);
    addLeft("Registry Editor", 7);
    // 与内核 `startmenu.zig` / `builtin_apps.zig` 左列顺序对齐；点击行为在帧缓冲 Shell 中实现。

    addRight("Documents", 2);
    addRight("Pictures", 10);
    addRight("Music", 11);
    addRight("Videos", 12);
    addRight("Downloads", 12);
    addRight("Games", 12);
    addRight("Computer", 1);
    addRight("Network", 5);
    addRight("Control Panel", 13);
    addRight("Devices and Printers", 22);
    addRight("Default Programs", 7);
    addRight("Help and Support", 7);
    addRight("Run...", 4);
}

pub fn toggle() void {
    visible = !visible;
    if (!visible) {
        search_len = 0;
    }
}

pub fn show() void {
    visible = true;
}

pub fn hide() void {
    visible = false;
    search_len = 0;
}

pub fn isVisible() bool {
    return visible;
}

pub fn contains(screen_h: i32, x: i32, y: i32) bool {
    const menu_h = theme.Layout.startmenu_height;
    const menu_w = theme.Layout.startmenu_width;
    const taskbar_h = theme.Layout.taskbar_height;
    const menu_y = screen_h - taskbar_h - menu_h;

    return x >= 0 and x < menu_w and y >= menu_y and y < menu_y + menu_h;
}

pub fn getLeftItems() []const MenuItem {
    return left_items[0..left_count];
}

pub fn getRightItems() []const MenuItem {
    return right_items[0..right_count];
}

pub fn getBackgroundColor() u32 {
    return theme.menu_bg;
}

pub fn getRightPanelColor() u32 {
    return theme.menu_right_bg;
}

pub fn getGlassBorderColor() u32 {
    return theme.menu_glass_border;
}
