//! ZirconOS Boot Manager — Text-Mode Boot Menu
//!
//! Renders a Windows 7 style boot menu on VGA text console (80×25)
//! or UEFI Simple Text Output Protocol.
//!
//! Layout (Windows Boot Manager style):
//! ┌──────────────────────────────────────────────────────────────────────────┐
//! │ Row 0-1:  Header bar (blue background)                                  │
//! │ Row 3:    "Choose an operating system to start:"                        │
//! │ Row 4:    "(Use the arrow keys to highlight your choice, then ENTER)"   │
//! │ Row 6-N:  Boot entries (highlighted = reverse video)                    │
//! │ Row N+2:  Separator line                                                │
//! │ Row N+4:  "Seconds until default starts: XX"                            │
//! │ Row 22:   Description / help text                                       │
//! │ Row 24:   Footer: "ENTER=Choose  TAB=Tools  ESC=Cancel"                 │
//! └──────────────────────────────────────────────────────────────────────────┘

const bcd = @import("bcd.zig");

pub const SCREEN_WIDTH: u32 = 80;
pub const SCREEN_HEIGHT: u32 = 25;
pub const VGA_TEXT_BASE: u32 = 0xB8000;

// ── Color Attributes ──

pub const Attr = struct {
    pub const HEADER: u8 = 0x1F; // White on blue
    pub const NORMAL: u8 = 0x07; // Light gray on black
    pub const HIGHLIGHT: u8 = 0x70; // Black on light gray
    pub const BORDER: u8 = 0x08; // Dark gray on black
    pub const TITLE: u8 = 0x0F; // White on black
    pub const FOOTER: u8 = 0x17; // Light gray on blue
    pub const TIMER: u8 = 0x0E; // Yellow on black
    pub const DESCRIPTION: u8 = 0x0B; // Light cyan on black
};

// ── Menu State ──

pub const MenuState = struct {
    selected: usize,
    entry_count: usize,
    timeout: u32,
    countdown: u32,
    timer_expired: bool,
    store: *const bcd.BcdStore,

    pub fn init(store: *const bcd.BcdStore) MenuState {
        return .{
            .selected = store.default_index,
            .entry_count = store.object_count,
            .timeout = store.timeout_seconds,
            .countdown = store.timeout_seconds,
            .timer_expired = false,
            .store = store,
        };
    }

    pub fn moveUp(self: *MenuState) void {
        if (self.selected > 0) {
            self.selected -= 1;
            self.resetTimer();
        }
    }

    pub fn moveDown(self: *MenuState) void {
        if (self.selected + 1 < self.entry_count) {
            self.selected += 1;
            self.resetTimer();
        }
    }

    pub fn tick(self: *MenuState) void {
        if (self.countdown > 0) {
            self.countdown -= 1;
        } else {
            self.timer_expired = true;
        }
    }

    pub fn resetTimer(self: *MenuState) void {
        self.countdown = self.timeout;
        self.timer_expired = false;
    }

    pub fn getSelectedMode(self: *const MenuState) bcd.BootMode {
        return self.store.getBootMode(self.selected);
    }

    pub fn getSelectedCmdline(self: *const MenuState) []const u8 {
        return self.store.getCommandLine(self.selected);
    }
};

// ── VGA Text Mode Renderer (BIOS/Protected Mode) ──
// Direct VGA memory writes at 0xB8000

pub const VgaRenderer = struct {
    base: [*]volatile u16,

    pub fn init() VgaRenderer {
        return .{
            .base = @ptrFromInt(VGA_TEXT_BASE),
        };
    }

    pub fn clear(self: *VgaRenderer, attr: u8) void {
        const fill: u16 = (@as(u16, attr) << 8) | ' ';
        for (0..(SCREEN_WIDTH * SCREEN_HEIGHT)) |i| {
            self.base[i] = fill;
        }
    }

    pub fn putChar(self: *VgaRenderer, row: u32, col: u32, ch: u8, attr: u8) void {
        if (row >= SCREEN_HEIGHT or col >= SCREEN_WIDTH) return;
        const offset = row * SCREEN_WIDTH + col;
        self.base[offset] = (@as(u16, attr) << 8) | ch;
    }

    pub fn putString(self: *VgaRenderer, row: u32, col: u32, str: []const u8, attr: u8) void {
        var c = col;
        for (str) |ch| {
            if (c >= SCREEN_WIDTH) break;
            self.putChar(row, c, ch, attr);
            c += 1;
        }
    }

    pub fn fillRow(self: *VgaRenderer, row: u32, attr: u8) void {
        for (0..SCREEN_WIDTH) |col| {
            self.putChar(row, @intCast(col), ' ', attr);
        }
    }

    pub fn putDecimal(self: *VgaRenderer, row: u32, col: u32, value: u32, attr: u8) void {
        var buf: [10]u8 = undefined;
        var len: usize = 0;
        var v = value;
        if (v == 0) {
            self.putChar(row, col, '0', attr);
            return;
        }
        while (v > 0) : (len += 1) {
            buf[len] = @intCast('0' + (v % 10));
            v /= 10;
        }
        var c = col;
        var i = len;
        while (i > 0) {
            i -= 1;
            self.putChar(row, c, buf[i], attr);
            c += 1;
        }
    }

    pub fn drawHorizontalLine(self: *VgaRenderer, row: u32, col_start: u32, col_end: u32, ch: u8, attr: u8) void {
        var c = col_start;
        while (c < col_end and c < SCREEN_WIDTH) : (c += 1) {
            self.putChar(row, c, ch, attr);
        }
    }
};

// ── Menu Rendering Functions ──

pub fn renderFullMenu(vga: *VgaRenderer, state: *const MenuState) void {
    vga.clear(Attr.NORMAL);

    renderHeader(vga);
    renderTitle(vga);
    renderEntries(vga, state);
    renderSeparator(vga, @intCast(8 + state.entry_count));
    renderTimer(vga, state, @intCast(10 + state.entry_count));
    renderDescription(vga, state, 22);
    renderFooter(vga);
}

fn renderHeader(vga: *VgaRenderer) void {
    vga.fillRow(0, Attr.HEADER);
    vga.fillRow(1, Attr.HEADER);

    const title = "ZirconOS Boot Manager";
    const col = (SCREEN_WIDTH - title.len) / 2;
    vga.putString(0, col, title, Attr.HEADER);

    const ver = "Version 1.0";
    const vcol = (SCREEN_WIDTH - ver.len) / 2;
    vga.putString(1, vcol, ver, Attr.HEADER);
}

fn renderTitle(vga: *VgaRenderer) void {
    vga.putString(3, 4, "Choose an operating system to start:", Attr.TITLE);
    vga.putString(4, 4, "(Use the arrow keys to highlight your choice, then press ENTER.)", Attr.NORMAL);
}

fn renderEntries(vga: *VgaRenderer, state: *const MenuState) void {
    for (0..state.entry_count) |i| {
        const row: u32 = @intCast(6 + i);
        const attr = if (i == state.selected) Attr.HIGHLIGHT else Attr.NORMAL;

        if (i == state.selected) {
            vga.fillRow(row, Attr.HIGHLIGHT);
        }

        vga.putString(row, 4, "  ", attr);

        if (state.store.getEntry(i)) |obj| {
            vga.putString(row, 6, obj.getDescription(), attr);
        }
    }
}

fn renderSeparator(vga: *VgaRenderer, row: u32) void {
    vga.drawHorizontalLine(row, 2, 78, 0xC4, Attr.BORDER); // ─
}

fn renderTimer(vga: *VgaRenderer, state: *const MenuState, row: u32) void {
    if (state.countdown > 0) {
        vga.putString(row, 4, "Seconds until the highlighted choice will be started automatically: ", Attr.TIMER);
        vga.putDecimal(row, 72, state.countdown, Attr.TIMER);
    } else {
        vga.putString(row, 4, "Booting selected entry...", Attr.TIMER);
    }
}

fn renderDescription(vga: *VgaRenderer, state: *const MenuState, row: u32) void {
    const mode = state.store.getBootMode(state.selected);
    const desc = switch (mode) {
        .normal => "Start ZirconOS normally.",
        .debug => "Start ZirconOS with debug logging and serial output enabled.",
        .safe_mode => "Start ZirconOS with minimal drivers and services.",
        .safe_mode_networking => "Start ZirconOS in safe mode with network support.",
        .safe_mode_cmdprompt => "Start ZirconOS in safe mode with command prompt only.",
        .recovery => "Start the ZirconOS Recovery Console for system repair.",
        .last_known_good => "Start ZirconOS using the last configuration that worked.",
    };
    vga.putString(row, 4, desc, Attr.DESCRIPTION);
}

fn renderFooter(vga: *VgaRenderer) void {
    vga.fillRow(24, Attr.FOOTER);
    vga.putString(24, 2, "ENTER=Choose", Attr.FOOTER);
    vga.putString(24, 18, "|", Attr.FOOTER);
    vga.putString(24, 20, "TAB=Tools", Attr.FOOTER);
    vga.putString(24, 33, "|", Attr.FOOTER);
    vga.putString(24, 35, "ESC=Advanced Options", Attr.FOOTER);
    vga.putString(24, 60, "|", Attr.FOOTER);
    vga.putString(24, 62, "F1=Help", Attr.FOOTER);
}

/// Update only the changed parts of the menu (entries + timer)
pub fn renderEntryUpdate(vga: *VgaRenderer, state: *const MenuState) void {
    renderEntries(vga, state);
    renderDescription(vga, state, 22);
}

pub fn renderTimerUpdate(vga: *VgaRenderer, state: *const MenuState) void {
    const row: u32 = @intCast(10 + state.entry_count);
    // Clear timer line
    for (4..SCREEN_WIDTH) |col| {
        vga.putChar(row, @intCast(col), ' ', Attr.NORMAL);
    }
    renderTimer(vga, state, row);
}
