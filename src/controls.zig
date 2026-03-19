//! Controls - ZirconOS Aero Visual Controls
//! Implements Windows Vista/7 Aero-styled UI controls: glass-effect
//! buttons with highlight glow, rounded corners, subtle hover
//! animations, modern green gradient progress bar, and ListView
//! with Aero sorting headers.
//! Reference: ReactOS comctl32 / uxtheme (dll/win32/comctl32/)

const theme = @import("theme.zig");

pub const COLORREF = theme.COLORREF;

// ── Common Control State ──

pub const ControlState = enum(u8) {
    normal = 0,
    hover = 1,
    pressed = 2,
    focused = 3,
    disabled = 4,
    checked = 5,
    checked_hover = 6,
    indeterminate = 7,
};

pub const Alignment = enum(u8) {
    left = 0,
    center = 1,
    right = 2,
};

// ── Push Button (Aero glow style) ──

pub const MAX_LABEL_LEN: usize = 48;

pub const PushButton = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = theme.BUTTON_MIN_WIDTH,
    height: i32 = theme.BUTTON_HEIGHT,
    label: [MAX_LABEL_LEN]u8 = [_]u8{0} ** MAX_LABEL_LEN,
    label_len: usize = 0,
    state: ControlState = .normal,
    is_default: bool = false,
    is_enabled: bool = true,
    command_id: u32 = 0,

    pub fn getLabel(self: *const PushButton) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn setLabel(self: *PushButton, text: []const u8) void {
        const n = @min(text.len, MAX_LABEL_LEN);
        @memcpy(self.label[0..n], text[0..n]);
        self.label_len = n;
    }

    pub fn hitTest(self: *const PushButton, mx: i32, my: i32) bool {
        return mx >= self.x and mx < self.x + self.width and
            my >= self.y and my < self.y + self.height;
    }

    pub fn getColors(self: *const PushButton) struct {
        face: COLORREF,
        highlight: COLORREF,
        shadow: COLORREF,
        text: COLORREF,
        border: COLORREF,
        glow: COLORREF,
    } {
        const colors = theme.getColors();
        if (!self.is_enabled) {
            return .{
                .face = theme.RGB(0xF4, 0xF4, 0xF4),
                .highlight = theme.RGB(0xFF, 0xFF, 0xFF),
                .shadow = theme.RGB(0xD0, 0xD0, 0xD0),
                .text = theme.RGB(0xA0, 0xA0, 0xA0),
                .border = theme.RGB(0xCC, 0xCC, 0xCC),
                .glow = theme.RGB(0xD0, 0xD0, 0xD0),
            };
        }
        return switch (self.state) {
            .pressed => .{
                .face = theme.interpolateColor(colors.button_face, theme.RGB(0xC0, 0xC0, 0xC0), 1, 3),
                .highlight = colors.button_shadow,
                .shadow = colors.button_highlight,
                .text = colors.button_text,
                .border = theme.RGB(0x3C, 0x7F, 0xB1),
                .glow = theme.interpolateColor(colors.button_glow, theme.RGB(0, 0, 0), 1, 4),
            },
            .hover => .{
                .face = theme.interpolateColor(colors.button_face, theme.RGB(0xFF, 0xFF, 0xFF), 1, 3),
                .highlight = colors.button_highlight,
                .shadow = colors.button_shadow,
                .text = colors.button_text,
                .border = theme.RGB(0x3C, 0x7F, 0xB1),
                .glow = colors.button_glow,
            },
            .focused => .{
                .face = colors.button_face,
                .highlight = colors.button_highlight,
                .shadow = colors.button_shadow,
                .text = colors.button_text,
                .border = theme.RGB(0x3C, 0x7F, 0xB1),
                .glow = colors.button_glow,
            },
            else => .{
                .face = colors.button_face,
                .highlight = colors.button_highlight,
                .shadow = colors.button_shadow,
                .text = colors.button_text,
                .border = theme.RGB(0xAC, 0xAC, 0xAC),
                .glow = theme.RGB(0xD0, 0xD0, 0xD0),
            },
        };
    }
};

// ── Text Box (Edit Control) ──

pub const MAX_TEXT_LEN: usize = 256;

pub const TextBox = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 200,
    height: i32 = theme.TEXTBOX_HEIGHT,
    text: [MAX_TEXT_LEN]u8 = [_]u8{0} ** MAX_TEXT_LEN,
    text_len: usize = 0,
    cursor_pos: usize = 0,
    selection_start: usize = 0,
    selection_end: usize = 0,
    scroll_offset: usize = 0,
    state: ControlState = .normal,
    is_password: bool = false,
    is_readonly: bool = false,
    is_enabled: bool = true,
    is_multiline: bool = false,
    max_length: usize = MAX_TEXT_LEN,
    placeholder: [48]u8 = [_]u8{0} ** 48,
    placeholder_len: usize = 0,
    show_reveal_button: bool = false,

    pub fn getText(self: *const TextBox) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn setText(self: *TextBox, t: []const u8) void {
        const n = @min(t.len, self.max_length);
        @memcpy(self.text[0..n], t[0..n]);
        self.text_len = n;
        self.cursor_pos = n;
    }

    pub fn insertChar(self: *TextBox, c: u8) bool {
        if (!self.is_enabled or self.is_readonly) return false;
        if (self.text_len >= self.max_length) return false;

        var i = self.text_len;
        while (i > self.cursor_pos) : (i -= 1) {
            self.text[i] = self.text[i - 1];
        }
        self.text[self.cursor_pos] = c;
        self.text_len += 1;
        self.cursor_pos += 1;
        return true;
    }

    pub fn deleteChar(self: *TextBox) bool {
        if (!self.is_enabled or self.is_readonly) return false;
        if (self.cursor_pos == 0) return false;

        var i = self.cursor_pos - 1;
        while (i < self.text_len - 1) : (i += 1) {
            self.text[i] = self.text[i + 1];
        }
        self.text_len -= 1;
        self.cursor_pos -= 1;
        return true;
    }

    pub fn hitTest(self: *const TextBox, mx: i32, my: i32) bool {
        return mx >= self.x and mx < self.x + self.width and
            my >= self.y and my < self.y + self.height;
    }

    pub fn getColors(self: *const TextBox) struct {
        bg: COLORREF,
        text_color: COLORREF,
        border: COLORREF,
        selection_bg: COLORREF,
        selection_text: COLORREF,
        placeholder_color: COLORREF,
    } {
        const colors = theme.getColors();
        if (!self.is_enabled) {
            return .{
                .bg = theme.RGB(0xF4, 0xF4, 0xF4),
                .text_color = theme.RGB(0xA0, 0xA0, 0xA0),
                .border = theme.RGB(0xCC, 0xCC, 0xCC),
                .selection_bg = theme.RGB(0xCC, 0xCC, 0xCC),
                .selection_text = theme.RGB(0x00, 0x00, 0x00),
                .placeholder_color = theme.RGB(0xC0, 0xC0, 0xC0),
            };
        }
        return .{
            .bg = theme.RGB(0xFF, 0xFF, 0xFF),
            .text_color = theme.RGB(0x00, 0x00, 0x00),
            .border = if (self.state == .focused) theme.RGB(0x3D, 0xA8, 0xF5) else theme.RGB(0xAB, 0xAD, 0xB3),
            .selection_bg = colors.selection_bg,
            .selection_text = colors.selection_text,
            .placeholder_color = theme.RGB(0xA0, 0xA0, 0xA0),
        };
    }
};

// ── Check Box ──

pub const CheckBox = struct {
    x: i32 = 0,
    y: i32 = 0,
    label: [MAX_LABEL_LEN]u8 = [_]u8{0} ** MAX_LABEL_LEN,
    label_len: usize = 0,
    is_checked: bool = false,
    state: ControlState = .normal,
    is_enabled: bool = true,

    pub fn getLabel(self: *const CheckBox) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn toggle(self: *CheckBox) void {
        if (self.is_enabled) {
            self.is_checked = !self.is_checked;
        }
    }

    pub fn hitTest(self: *const CheckBox, mx: i32, my: i32) bool {
        const w = theme.CHECKBOX_SIZE + 4 + @as(i32, @intCast(self.label_len * 7));
        return mx >= self.x and mx < self.x + w and
            my >= self.y and my < self.y + theme.CHECKBOX_SIZE;
    }

    pub fn getCheckboxColors(self: *const CheckBox) struct {
        box_bg: COLORREF,
        box_border: COLORREF,
        check_color: COLORREF,
        text_color: COLORREF,
    } {
        const colors = theme.getColors();
        _ = self;
        return .{
            .box_bg = theme.RGB(0xFF, 0xFF, 0xFF),
            .box_border = theme.RGB(0x83, 0x83, 0x83),
            .check_color = theme.RGB(0x21, 0x7E, 0x21),
            .text_color = colors.button_text,
        };
    }
};

// ── Radio Button ──

pub const RadioButton = struct {
    x: i32 = 0,
    y: i32 = 0,
    label: [MAX_LABEL_LEN]u8 = [_]u8{0} ** MAX_LABEL_LEN,
    label_len: usize = 0,
    is_selected: bool = false,
    group_id: u32 = 0,
    state: ControlState = .normal,
    is_enabled: bool = true,

    pub fn getLabel(self: *const RadioButton) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn hitTest(self: *const RadioButton, mx: i32, my: i32) bool {
        const w = theme.RADIO_SIZE + 4 + @as(i32, @intCast(self.label_len * 7));
        return mx >= self.x and mx < self.x + w and
            my >= self.y and my < self.y + theme.RADIO_SIZE;
    }
};

// ── Progress Bar (green gradient, Vista/7 style) ──

pub const ProgressBar = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 200,
    height: i32 = 17,
    min_value: u32 = 0,
    max_value: u32 = 100,
    current_value: u32 = 0,
    is_marquee: bool = false,
    marquee_pos: i32 = 0,

    pub fn getPercentage(self: *const ProgressBar) u32 {
        const range = self.max_value - self.min_value;
        if (range == 0) return 0;
        return (self.current_value - self.min_value) * 100 / range;
    }

    pub fn getFillWidth(self: *const ProgressBar) i32 {
        const pct = self.getPercentage();
        return @divTrunc(self.width * @as(i32, @intCast(pct)), 100);
    }

    pub fn getColors(_: *const ProgressBar) struct {
        bg: COLORREF,
        fill_left: COLORREF,
        fill_right: COLORREF,
        border: COLORREF,
        glow: COLORREF,
    } {
        const colors = theme.getColors();
        return .{
            .bg = theme.RGB(0xE6, 0xE6, 0xE6),
            .fill_left = colors.progress_fill_left,
            .fill_right = colors.progress_fill_right,
            .border = theme.RGB(0xBC, 0xBC, 0xBC),
            .glow = theme.RGB(0x80, 0xF0, 0x80),
        };
    }
};

// ── List View (with Aero sorting headers) ──

pub const MAX_LIST_ITEMS: usize = 64;

pub const SortDirection = enum(u8) {
    none = 0,
    ascending = 1,
    descending = 2,
};

pub const ListViewHeader = struct {
    text: [32]u8 = [_]u8{0} ** 32,
    text_len: usize = 0,
    width: i32 = 100,
    sort: SortDirection = .none,
    is_hover: bool = false,

    pub fn getText(self: *const ListViewHeader) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const ListItem = struct {
    text: [64]u8 = [_]u8{0} ** 64,
    text_len: usize = 0,
    data: u64 = 0,
    is_selected: bool = false,

    pub fn getText(self: *const ListItem) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const ListBox = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 160,
    height: i32 = 120,
    items: [MAX_LIST_ITEMS]ListItem = [_]ListItem{.{}} ** MAX_LIST_ITEMS,
    item_count: usize = 0,
    selected_index: i32 = -1,
    scroll_top: usize = 0,
    is_enabled: bool = true,
    is_multi_select: bool = false,
    item_height: i32 = 18,

    pub fn addItem(self: *ListBox, text: []const u8, data: u64) bool {
        if (self.item_count >= MAX_LIST_ITEMS) return false;
        var item = &self.items[self.item_count];
        item.* = .{};
        item.data = data;
        const n = @min(text.len, item.text.len);
        @memcpy(item.text[0..n], text[0..n]);
        item.text_len = n;
        self.item_count += 1;
        return true;
    }

    pub fn getVisibleCount(self: *const ListBox) usize {
        if (self.item_height <= 0) return 0;
        return @intCast(@divTrunc(self.height, self.item_height));
    }

    pub fn hitTest(self: *const ListBox, mx: i32, my: i32) ?usize {
        if (mx < self.x or mx >= self.x + self.width) return null;
        if (my < self.y or my >= self.y + self.height) return null;
        if (self.item_height <= 0) return null;
        const rel_y = my - self.y;
        const idx = self.scroll_top + @as(usize, @intCast(@divTrunc(rel_y, self.item_height)));
        if (idx < self.item_count) return idx;
        return null;
    }
};

// ── Tooltip ──

pub const Tooltip = struct {
    text: [128]u8 = [_]u8{0} ** 128,
    text_len: usize = 0,
    x: i32 = 0,
    y: i32 = 0,
    is_visible: bool = false,
    show_delay: u32 = 500,
    timer: u32 = 0,

    pub fn getText(self: *const Tooltip) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn show(self: *Tooltip, text: []const u8, x: i32, y: i32) void {
        const n = @min(text.len, self.text.len);
        @memcpy(self.text[0..n], text[0..n]);
        self.text_len = n;
        self.x = x;
        self.y = y;
        self.is_visible = true;
    }

    pub fn hide(self: *Tooltip) void {
        self.is_visible = false;
    }

    pub fn getColors(_: *const Tooltip) struct {
        bg: COLORREF,
        text_color: COLORREF,
        border: COLORREF,
    } {
        const colors = theme.getColors();
        return .{
            .bg = colors.tooltip_bg,
            .text_color = colors.tooltip_text,
            .border = theme.RGB(0x76, 0x76, 0x76),
        };
    }
};

// ── Group Box ──

pub const GroupBox = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 200,
    height: i32 = 100,
    label: [MAX_LABEL_LEN]u8 = [_]u8{0} ** MAX_LABEL_LEN,
    label_len: usize = 0,

    pub fn getLabel(self: *const GroupBox) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn getColors(_: *const GroupBox) struct {
        border: COLORREF,
        text: COLORREF,
        bg: COLORREF,
    } {
        const colors = theme.getColors();
        return .{
            .border = theme.RGB(0xD5, 0xDF, 0xE5),
            .text = theme.RGB(0x00, 0x33, 0x99),
            .bg = colors.button_face,
        };
    }
};

// ── Search Box (Aero Start Menu search) ──

pub const SearchBox = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 180,
    height: i32 = theme.STARTMENU_SEARCH_HEIGHT,
    text: [128]u8 = [_]u8{0} ** 128,
    text_len: usize = 0,
    cursor_pos: usize = 0,
    state: ControlState = .normal,
    is_enabled: bool = true,

    pub fn getText(self: *const SearchBox) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn insertChar(self: *SearchBox, c: u8) bool {
        if (!self.is_enabled) return false;
        if (self.text_len >= self.text.len) return false;
        self.text[self.text_len] = c;
        self.text_len += 1;
        self.cursor_pos += 1;
        return true;
    }

    pub fn getColors(_: *const SearchBox) struct {
        bg: COLORREF,
        text_color: COLORREF,
        border: COLORREF,
        icon_color: COLORREF,
    } {
        const colors = theme.getColors();
        return .{
            .bg = colors.search_box_bg,
            .text_color = theme.RGB(0x00, 0x00, 0x00),
            .border = colors.search_box_border,
            .icon_color = theme.RGB(0x7A, 0xB0, 0xDA),
        };
    }
};

// ── Initialization ──

pub fn init() void {
    // Controls module ready
}
