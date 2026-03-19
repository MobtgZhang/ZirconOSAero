//! Desktop Manager - ZirconOS Aero Desktop
//! Manages the desktop surface including wallpaper rendering,
//! icon layout (Vista/7 style), glass-effect right-click context menu,
//! and Aero wallpaper with DWM color extraction.
//! Reference: ReactOS explorer shell (base/shell/explorer/)

const theme = @import("theme.zig");

pub const COLORREF = theme.COLORREF;

// ── Desktop Icon ──

pub const MAX_DESKTOP_ICONS: usize = 64;
pub const MAX_ICON_NAME_LEN: usize = 48;
pub const MAX_ICON_PATH_LEN: usize = 128;

pub const IconType = enum(u8) {
    computer = 0,
    user_files = 1,
    network = 2,
    recycle_bin = 3,
    control_panel = 4,
    folder = 5,
    file = 6,
    shortcut = 7,
    internet_explorer = 8,
};

pub const DesktopIcon = struct {
    name: [MAX_ICON_NAME_LEN]u8 = [_]u8{0} ** MAX_ICON_NAME_LEN,
    name_len: usize = 0,
    target_path: [MAX_ICON_PATH_LEN]u8 = [_]u8{0} ** MAX_ICON_PATH_LEN,
    target_path_len: usize = 0,
    icon_type: IconType = .file,
    grid_x: i32 = 0,
    grid_y: i32 = 0,
    pixel_x: i32 = 0,
    pixel_y: i32 = 0,
    is_selected: bool = false,
    is_visible: bool = true,
    is_system: bool = false,

    pub fn getName(self: *const DesktopIcon) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getTargetPath(self: *const DesktopIcon) []const u8 {
        return self.target_path[0..self.target_path_len];
    }
};

// ── Wallpaper ──

pub const WallpaperStyle = enum(u8) {
    center = 0,
    tile = 1,
    stretch = 2,
    fit = 3,
    fill = 4,
    solid_color = 5,
};

pub const Wallpaper = struct {
    path: [MAX_ICON_PATH_LEN]u8 = [_]u8{0} ** MAX_ICON_PATH_LEN,
    path_len: usize = 0,
    style: WallpaperStyle = .solid_color,
    solid_color: COLORREF = 0,
    is_set: bool = false,
    dwm_accent_color: COLORREF = 0,
    dwm_accent_extracted: bool = false,

    pub fn getPath(self: *const Wallpaper) []const u8 {
        return self.path[0..self.path_len];
    }
};

// ── Context Menu (glass effect) ──

pub const MAX_CONTEXT_ITEMS: usize = 16;

pub const ContextMenuItemType = enum(u8) {
    normal = 0,
    separator = 1,
    submenu = 2,
    checked = 3,
    disabled = 4,
};

pub const ContextMenuItem = struct {
    label: [48]u8 = [_]u8{0} ** 48,
    label_len: usize = 0,
    item_type: ContextMenuItemType = .normal,
    command_id: u32 = 0,
    is_highlighted: bool = false,
    icon_id: u32 = 0,

    pub fn getLabel(self: *const ContextMenuItem) []const u8 {
        return self.label[0..self.label_len];
    }
};

pub const ContextMenu = struct {
    items: [MAX_CONTEXT_ITEMS]ContextMenuItem = [_]ContextMenuItem{.{}} ** MAX_CONTEXT_ITEMS,
    item_count: usize = 0,
    x: i32 = 0,
    y: i32 = 0,
    is_visible: bool = false,
    highlight_index: i32 = -1,
    has_glass: bool = true,
};

// ── Desktop Arrangement ──

pub const ArrangeBy = enum(u8) {
    name = 0,
    size = 1,
    file_type = 2,
    date_modified = 3,
};

pub const DesktopSettings = struct {
    show_computer: bool = true,
    show_user_files: bool = true,
    show_network: bool = true,
    show_recycle_bin: bool = true,
    show_control_panel: bool = false,
    auto_arrange: bool = true,
    align_to_grid: bool = true,
    arrange_by: ArrangeBy = .name,
    icon_spacing_x: i32 = theme.DESKTOP_ICON_SPACING_X,
    icon_spacing_y: i32 = theme.DESKTOP_ICON_SPACING_Y,
};

// ── Global State ──

var icons: [MAX_DESKTOP_ICONS]DesktopIcon = [_]DesktopIcon{.{}} ** MAX_DESKTOP_ICONS;
var icon_count: usize = 0;
var wallpaper: Wallpaper = .{};
var context_menu: ContextMenu = .{};
var settings: DesktopSettings = .{};

var desktop_width: i32 = 800;
var desktop_height: i32 = 600;
var desktop_initialized: bool = false;

// ── Icon Management ──

pub fn addIcon(
    name: []const u8,
    target_path: []const u8,
    icon_type: IconType,
    is_system: bool,
) ?*DesktopIcon {
    if (icon_count >= MAX_DESKTOP_ICONS) return null;

    var icon = &icons[icon_count];
    icon.* = .{};
    icon.icon_type = icon_type;
    icon.is_system = is_system;
    icon.is_visible = true;

    const nn = @min(name.len, MAX_ICON_NAME_LEN);
    @memcpy(icon.name[0..nn], name[0..nn]);
    icon.name_len = nn;

    const tp = @min(target_path.len, MAX_ICON_PATH_LEN);
    @memcpy(icon.target_path[0..tp], target_path[0..tp]);
    icon.target_path_len = tp;

    arrangeIcon(icon, icon_count);
    icon_count += 1;
    return icon;
}

pub fn removeIcon(index: usize) bool {
    if (index >= icon_count) return false;
    if (icons[index].is_system) return false;
    var j = index;
    while (j + 1 < icon_count) : (j += 1) {
        icons[j] = icons[j + 1];
    }
    icons[icon_count - 1] = .{};
    icon_count -= 1;
    rearrangeIcons();
    return true;
}

pub fn getIcon(index: usize) ?*const DesktopIcon {
    if (index < icon_count and icons[index].is_visible) {
        return &icons[index];
    }
    return null;
}

pub fn getIconCount() usize {
    return icon_count;
}

pub fn selectIcon(index: usize) void {
    for (icons[0..icon_count]) |*icon| {
        icon.is_selected = false;
    }
    if (index < icon_count) {
        icons[index].is_selected = true;
    }
}

pub fn deselectAll() void {
    for (icons[0..icon_count]) |*icon| {
        icon.is_selected = false;
    }
}

pub fn hitTestIcon(x: i32, y: i32) ?usize {
    var i: usize = icon_count;
    while (i > 0) {
        i -= 1;
        const icon = &icons[i];
        if (!icon.is_visible) continue;
        if (x >= icon.pixel_x and
            x < icon.pixel_x + theme.DESKTOP_ICON_SPACING_X and
            y >= icon.pixel_y and
            y < icon.pixel_y + theme.DESKTOP_ICON_SPACING_Y)
        {
            return i;
        }
    }
    return null;
}

fn arrangeIcon(icon: *DesktopIcon, index: usize) void {
    const margin = theme.DESKTOP_ICON_MARGIN;
    const spacing_x = settings.icon_spacing_x;
    const spacing_y = settings.icon_spacing_y;
    const max_rows: usize = @intCast(@divTrunc(desktop_height - theme.TASKBAR_HEIGHT - margin, spacing_y));
    const effective_max = if (max_rows > 0) max_rows else 1;

    icon.grid_x = @intCast(index / effective_max);
    icon.grid_y = @intCast(index % effective_max);
    icon.pixel_x = margin + icon.grid_x * spacing_x;
    icon.pixel_y = margin + icon.grid_y * spacing_y;
}

pub fn rearrangeIcons() void {
    var visible_idx: usize = 0;
    for (icons[0..icon_count]) |*icon| {
        if (icon.is_visible) {
            arrangeIcon(icon, visible_idx);
            visible_idx += 1;
        }
    }
}

// ── Wallpaper ──

pub fn setWallpaper(path: []const u8, style: WallpaperStyle) void {
    const n = @min(path.len, wallpaper.path.len);
    @memcpy(wallpaper.path[0..n], path[0..n]);
    wallpaper.path_len = n;
    wallpaper.style = style;
    wallpaper.is_set = true;
}

pub fn setWallpaperColor(color: COLORREF) void {
    wallpaper.style = .solid_color;
    wallpaper.solid_color = color;
    wallpaper.is_set = true;
}

pub fn getWallpaper() *const Wallpaper {
    return &wallpaper;
}

pub fn getDesktopColor() COLORREF {
    if (wallpaper.is_set and wallpaper.style == .solid_color) {
        return wallpaper.solid_color;
    }
    return theme.getColors().desktop_background;
}

pub fn extractDwmAccentColor(color: COLORREF) void {
    wallpaper.dwm_accent_color = color;
    wallpaper.dwm_accent_extracted = true;
}

// ── Context Menu (glass-effect) ──

pub fn showContextMenu(x: i32, y: i32) void {
    context_menu = .{};
    context_menu.x = x;
    context_menu.y = y;
    context_menu.is_visible = true;
    context_menu.has_glass = theme.isGlassEnabled();

    addContextItem("View", .submenu, 100, 0);
    addContextItem("Sort by", .submenu, 101, 0);
    addContextItem("Refresh", .normal, 102, 0);
    addContextItem("", .separator, 0, 0);
    addContextItem("Paste", .disabled, 103, 0);
    addContextItem("Paste shortcut", .disabled, 104, 0);
    addContextItem("", .separator, 0, 0);
    addContextItem("New", .submenu, 110, 0);
    addContextItem("", .separator, 0, 0);
    addContextItem("Personalize", .normal, 120, 0);
}

pub fn hideContextMenu() void {
    context_menu.is_visible = false;
}

pub fn getContextMenu() *const ContextMenu {
    return &context_menu;
}

fn addContextItem(label: []const u8, item_type: ContextMenuItemType, cmd_id: u32, icon_id: u32) void {
    if (context_menu.item_count >= MAX_CONTEXT_ITEMS) return;
    var item = &context_menu.items[context_menu.item_count];
    item.* = .{};
    item.item_type = item_type;
    item.command_id = cmd_id;
    item.icon_id = icon_id;
    const n = @min(label.len, item.label.len);
    @memcpy(item.label[0..n], label[0..n]);
    item.label_len = n;
    context_menu.item_count += 1;
}

// ── Settings ──

pub fn getSettings() *const DesktopSettings {
    return &settings;
}

pub fn setDesktopSize(width: i32, height: i32) void {
    desktop_width = width;
    desktop_height = height;
    rearrangeIcons();
}

pub fn getDesktopSize() struct { width: i32, height: i32 } {
    return .{ .width = desktop_width, .height = desktop_height };
}

// ── Initialization ──

fn createSystemIcons() void {
    if (settings.show_computer) {
        _ = addIcon("Computer", "C:\\", .computer, true);
    }
    if (settings.show_user_files) {
        _ = addIcon("User's Files", "C:\\Users\\User", .user_files, true);
    }
    if (settings.show_network) {
        _ = addIcon("Network", "\\\\Network", .network, true);
    }
    if (settings.show_recycle_bin) {
        _ = addIcon("Recycle Bin", "C:\\$Recycle.Bin", .recycle_bin, true);
    }
}

pub fn init() void {
    icon_count = 0;
    context_menu = .{};
    settings = .{};

    const colors = theme.getColors();
    setWallpaperColor(colors.desktop_background);
    createSystemIcons();

    desktop_initialized = true;
}
