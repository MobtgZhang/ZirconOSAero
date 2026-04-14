// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! ZirconOS Boot Manager — Text-Mode Boot Menu
//!
//! Renders a Windows 7–style boot menu on VGA text console (80×25).
//!
//! Layout (aligned with Windows Boot Manager text UI):
//! - Row 0:    Single grey header bar, title centered (black on light grey)
//! - Row 2–3:  Choose / TAB hint + parenthetical arrow-key hint
//! - Row 5+:   OS entries (full-width grey highlight; `>` at right column)
//! - After list: F8 advanced-options line; countdown; “Tools:” + tool line(s)
//! - Row 24:   Grey footer bar — ENTER=Choose | TAB=Menu | ESC=Cancel

const bcd = @import("bcd.zig");

pub const SCREEN_WIDTH: u32 = 80;
pub const SCREEN_HEIGHT: u32 = 25;
pub const VGA_TEXT_BASE: u32 = 0xB8000;

/// One placeholder tool row (matches “Tools” section in Win7-style UI).
pub const tool_placeholder_line = "ZirconOS Memory Diagnostic";

// ── Color Attributes ──

pub const Attr = struct {
    /// Light grey background, black foreground (header, footer, selection bar)
    pub const BAR: u8 = 0x70;
    pub const NORMAL: u8 = 0x07; // Light gray on black
    pub const HIGHLIGHT: u8 = 0x70; // Same as Win7 selection bar
    pub const TITLE: u8 = 0x0F; // White on black
    pub const TIMER: u8 = 0x0E; // Yellow on black
};

// ── Row layout (80×25, footer fixed at row 24) ──

pub fn rowEntryFirst() u32 {
    return 5;
}

fn rowF8(entry_count: usize) u32 {
    return @intCast(6 + entry_count);
}

fn rowTimer(entry_count: usize) u32 {
    return @intCast(8 + entry_count);
}

fn rowToolsLabel(entry_count: usize) u32 {
    return @intCast(10 + entry_count);
}

fn rowToolsFirst(entry_count: usize) u32 {
    return @intCast(11 + entry_count);
}

pub const FOOTER_ROW: u32 = 24;

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
};

// ── Menu Rendering Functions ──

pub fn renderFullMenu(vga: *VgaRenderer, state: *const MenuState) void {
    vga.clear(Attr.NORMAL);

    renderHeader(vga);
    renderTitle(vga);
    renderEntries(vga, state);
    renderF8Line(vga, state.entry_count);
    renderTimer(vga, state, rowTimer(state.entry_count));
    renderToolsSection(vga, state.entry_count);
    renderFooter(vga);
}

fn renderHeader(vga: *VgaRenderer) void {
    vga.fillRow(0, Attr.BAR);
    const title = "ZirconOSAero Boot Manager";
    const col = (SCREEN_WIDTH - @as(u32, @intCast(title.len))) / 2;
    vga.putString(0, col, title, Attr.BAR);
}

fn renderTitle(vga: *VgaRenderer) void {
    vga.putString(2, 4, "Choose an operating system to start, or press TAB to select a tool:", Attr.TITLE);
    vga.putString(3, 4, "(Use the arrow keys to highlight your choice, then press ENTER.)", Attr.NORMAL);
}

fn renderEntries(vga: *VgaRenderer, state: *const MenuState) void {
    const first = rowEntryFirst();
    for (0..state.entry_count) |i| {
        const row: u32 = first + @as(u32, @intCast(i));
        const sel = i == state.selected;
        if (sel) {
            vga.fillRow(row, Attr.HIGHLIGHT);
        }
        const attr: u8 = if (sel) Attr.HIGHLIGHT else Attr.NORMAL;
        if (state.store.getEntry(i)) |obj| {
            vga.putString(row, 4, obj.getDescription(), attr);
        }
        if (sel) {
            vga.putChar(row, SCREEN_WIDTH - 2, '>', attr);
        }
    }
}

fn renderF8Line(vga: *VgaRenderer, entry_count: usize) void {
    const row = rowF8(entry_count);
    vga.putString(row, 4, "To specify an advanced option for this choice, press F8.", Attr.NORMAL);
}

fn renderTimer(vga: *VgaRenderer, state: *const MenuState, row: u32) void {
    if (state.countdown > 0) {
        vga.putString(row, 4, "Seconds until the highlighted choice will be started automatically: ", Attr.TIMER);
        vga.putDecimal(row, 72, state.countdown, Attr.TIMER);
    } else {
        vga.putString(row, 4, "Booting selected entry...", Attr.TIMER);
    }
}

fn renderToolsSection(vga: *VgaRenderer, entry_count: usize) void {
    const label_row = rowToolsLabel(entry_count);
    const item_row = rowToolsFirst(entry_count);
    vga.putString(label_row, 4, "Tools:", Attr.TITLE);
    vga.putString(item_row, 4, tool_placeholder_line, Attr.NORMAL);
}

fn renderFooter(vga: *VgaRenderer) void {
    vga.fillRow(FOOTER_ROW, Attr.BAR);
    const left = "ENTER=Choose";
    const mid = "TAB=Menu";
    const right = "ESC=Cancel";
    vga.putString(FOOTER_ROW, 2, left, Attr.BAR);
    const mid_col = (SCREEN_WIDTH - @as(u32, @intCast(mid.len))) / 2;
    vga.putString(FOOTER_ROW, mid_col, mid, Attr.BAR);
    const rcol = SCREEN_WIDTH - @as(u32, @intCast(right.len)) - 1;
    vga.putString(FOOTER_ROW, rcol, right, Attr.BAR);
}

/// Redraw OS list rows only (same geometry as `renderFullMenu`).
pub fn renderEntryUpdate(vga: *VgaRenderer, state: *const MenuState) void {
    renderEntries(vga, state);
}

pub fn renderTimerUpdate(vga: *VgaRenderer, state: *const MenuState) void {
    const row = rowTimer(state.entry_count);
    for (4..SCREEN_WIDTH) |col| {
        vga.putChar(row, @intCast(col), ' ', Attr.NORMAL);
    }
    renderTimer(vga, state, row);
}
