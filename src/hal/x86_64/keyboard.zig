//! PS/2 Keyboard Driver
//! Translates scan code set 1 to ASCII characters
//! Uses a ring buffer to queue keypresses for the shell

const portio = @import("portio.zig");
const CursorNudge = @import("../../drivers/input/cursor_types.zig").CursorNudge;

const KB_DATA_PORT: u16 = 0x60;
const KB_STATUS_PORT: u16 = 0x64;

const RING_SIZE: usize = 128;

var ring_buf: [RING_SIZE]u8 = [_]u8{0} ** RING_SIZE;
var ring_head: usize = 0;
var ring_tail: usize = 0;
var shift_held: bool = false;
var ctrl_held: bool = false;
var alt_held: bool = false;
var caps_lock: bool = false;
var initialized: bool = false;

/// Ctrl+Shift+Esc → Task Manager (desktop shell; consumed via `consumeTaskMgrHotkey`)
var taskmgr_hotkey_pending: bool = false;
/// Ctrl+Alt+F9 → 循环 Aero 壁纸预设（`consumeWallpaperCycleHotkey`）
var wallpaper_cycle_pending: bool = false;
/// Alt+Tab（make 0x0F）→ Flip3D 近似切换（`consumeFlip3dHotkey`）
var flip3d_hotkey_pending: bool = false;
/// Esc（make 0x01，且非 Ctrl+Shift+Esc）→ 关闭 Flip3D 覆盖层（`consumeFlip3dDismiss`）
var flip3d_dismiss_pending: bool = false;

/// 扩展键前缀（方向键等为 E0 xx）
var e0_prefix: bool = false;
/// 方向键微移光标（PS/2 不可用时兜底）
var cursor_nudge_dx: i32 = 0;
var cursor_nudge_dy: i32 = 0;

const scancode_normal: [128]u8 = blk: {
    var table = [_]u8{0} ** 128;
    table[0x02] = '1';
    table[0x03] = '2';
    table[0x04] = '3';
    table[0x05] = '4';
    table[0x06] = '5';
    table[0x07] = '6';
    table[0x08] = '7';
    table[0x09] = '8';
    table[0x0A] = '9';
    table[0x0B] = '0';
    table[0x0C] = '-';
    table[0x0D] = '=';
    table[0x0E] = 0x08; // backspace
    table[0x0F] = '\t';
    table[0x10] = 'q';
    table[0x11] = 'w';
    table[0x12] = 'e';
    table[0x13] = 'r';
    table[0x14] = 't';
    table[0x15] = 'y';
    table[0x16] = 'u';
    table[0x17] = 'i';
    table[0x18] = 'o';
    table[0x19] = 'p';
    table[0x1A] = '[';
    table[0x1B] = ']';
    table[0x1C] = '\n'; // enter
    table[0x1E] = 'a';
    table[0x1F] = 's';
    table[0x20] = 'd';
    table[0x21] = 'f';
    table[0x22] = 'g';
    table[0x23] = 'h';
    table[0x24] = 'j';
    table[0x25] = 'k';
    table[0x26] = 'l';
    table[0x27] = ';';
    table[0x28] = '\'';
    table[0x29] = '`';
    table[0x2B] = '\\';
    table[0x2C] = 'z';
    table[0x2D] = 'x';
    table[0x2E] = 'c';
    table[0x2F] = 'v';
    table[0x30] = 'b';
    table[0x31] = 'n';
    table[0x32] = 'm';
    table[0x33] = ',';
    table[0x34] = '.';
    table[0x35] = '/';
    table[0x39] = ' ';
    break :blk table;
};

const scancode_shift: [128]u8 = blk: {
    var table = [_]u8{0} ** 128;
    table[0x02] = '!';
    table[0x03] = '@';
    table[0x04] = '#';
    table[0x05] = '$';
    table[0x06] = '%';
    table[0x07] = '^';
    table[0x08] = '&';
    table[0x09] = '*';
    table[0x0A] = '(';
    table[0x0B] = ')';
    table[0x0C] = '_';
    table[0x0D] = '+';
    table[0x0E] = 0x08;
    table[0x0F] = '\t';
    table[0x10] = 'Q';
    table[0x11] = 'W';
    table[0x12] = 'E';
    table[0x13] = 'R';
    table[0x14] = 'T';
    table[0x15] = 'Y';
    table[0x16] = 'U';
    table[0x17] = 'I';
    table[0x18] = 'O';
    table[0x19] = 'P';
    table[0x1A] = '{';
    table[0x1B] = '}';
    table[0x1C] = '\n';
    table[0x1E] = 'A';
    table[0x1F] = 'S';
    table[0x20] = 'D';
    table[0x21] = 'F';
    table[0x22] = 'G';
    table[0x23] = 'H';
    table[0x24] = 'J';
    table[0x25] = 'K';
    table[0x26] = 'L';
    table[0x27] = ':';
    table[0x28] = '"';
    table[0x29] = '~';
    table[0x2B] = '|';
    table[0x2C] = 'Z';
    table[0x2D] = 'X';
    table[0x2E] = 'C';
    table[0x2F] = 'V';
    table[0x30] = 'B';
    table[0x31] = 'N';
    table[0x32] = 'M';
    table[0x33] = '<';
    table[0x34] = '>';
    table[0x35] = '?';
    table[0x39] = ' ';
    break :blk table;
};

pub fn init() void {
    ring_head = 0;
    ring_tail = 0;
    shift_held = false;
    ctrl_held = false;
    alt_held = false;
    caps_lock = false;
    initialized = true;
}

fn toUpper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

pub fn handleIrq() void {
    handleScancodeByte(portio.inb(KB_DATA_PORT));
}

pub fn takeCursorNudge() CursorNudge {
    const r = CursorNudge{ .dx = cursor_nudge_dx, .dy = cursor_nudge_dy };
    cursor_nudge_dx = 0;
    cursor_nudge_dy = 0;
    return r;
}

/// Process one PS/2 scan code (also used when draining the 8042 buffer from the mouse poll path).
pub fn handleScancodeByte(scancode: u8) void {
    if (scancode == 0xE0) {
        e0_prefix = true;
        return;
    }
    if (scancode & 0x80 != 0) {
        if (e0_prefix) e0_prefix = false;
        const released = scancode & 0x7F;
        if (released == 0x2A or released == 0x36) shift_held = false;
        if (released == 0x1D) ctrl_held = false;
        if (released == 0x38) alt_held = false;
        return;
    }

    if (e0_prefix) {
        e0_prefix = false;
        const step: i32 = 12;
        switch (scancode) {
            0x48 => cursor_nudge_dy -= step,
            0x50 => cursor_nudge_dy += step,
            0x4B => cursor_nudge_dx -= step,
            0x4D => cursor_nudge_dx += step,
            else => {},
        }
        return;
    }

    if (scancode == 0x2A or scancode == 0x36) {
        shift_held = true;
        return;
    }
    if (scancode == 0x1D) {
        ctrl_held = true;
        return;
    }
    if (scancode == 0x38) {
        alt_held = true;
        return;
    }
    if (scancode == 0x3A) {
        caps_lock = !caps_lock;
        return;
    }

    // Ctrl+Alt+F9：与 evdev 路径一致，切换壁纸预设（先于 WASD 微移处理）
    if (scancode == 0x43 and ctrl_held and alt_held) {
        wallpaper_cycle_pending = true;
        return;
    }

    // Alt+Tab：Tab make 0x0F（先于字符入环，避免把 Tab 当文本）
    if (scancode == 0x0F and alt_held and !ctrl_held) {
        flip3d_hotkey_pending = true;
        return;
    }

    // WASD 微移光标（PS/2 不可用时仍可操作桌面）
    const kstep: i32 = 10;
    switch (scancode) {
        0x11 => {
            cursor_nudge_dy -= kstep;
            return;
        }, // W
        0x1E => {
            cursor_nudge_dx -= kstep;
            return;
        }, // A
        0x1F => {
            cursor_nudge_dy += kstep;
            return;
        }, // S
        0x20 => {
            cursor_nudge_dx += kstep;
            return;
        }, // D
        else => {},
    }

    // Esc (make 0x01)：Ctrl+Shift+Esc → 任务管理器；否则 → 关闭 Flip3D（若壳层已打开）
    if (scancode == 0x01) {
        if (ctrl_held and shift_held) {
            taskmgr_hotkey_pending = true;
        } else {
            flip3d_dismiss_pending = true;
        }
    }

    if (scancode >= 128) return;

    var ch: u8 = 0;
    if (shift_held) {
        ch = scancode_shift[scancode];
    } else {
        ch = scancode_normal[scancode];
    }

    if (ch == 0) return;

    if (caps_lock and !shift_held and ch >= 'a' and ch <= 'z') {
        ch = toUpper(ch);
    } else if (caps_lock and shift_held and ch >= 'A' and ch <= 'Z') {
        ch = toLower(ch);
    }

    if (ctrl_held) {
        if (ch >= 'a' and ch <= 'z') ch = ch - 'a' + 1;
        if (ch >= 'A' and ch <= 'Z') ch = ch - 'A' + 1;
    }

    pushChar(ch);
}

fn pushChar(ch: u8) void {
    const next = (ring_head + 1) % RING_SIZE;
    if (next == ring_tail) return;
    ring_buf[ring_head] = ch;
    ring_head = next;
}

/// 屏幕键盘等注入字符（与 IRQ 路径共用环形缓冲）。
pub fn injectSyntheticChar(ch: u8) void {
    pushChar(ch);
}

pub fn readChar() ?u8 {
    if (ring_head == ring_tail) return null;
    const ch = ring_buf[ring_tail];
    ring_tail = (ring_tail + 1) % RING_SIZE;
    return ch;
}

pub fn hasData() bool {
    return ring_head != ring_tail;
}

pub fn isInitialized() bool {
    return initialized;
}

pub fn consumeTaskMgrHotkey() bool {
    if (taskmgr_hotkey_pending) {
        taskmgr_hotkey_pending = false;
        return true;
    }
    return false;
}

pub fn consumeWallpaperCycleHotkey() bool {
    if (wallpaper_cycle_pending) {
        wallpaper_cycle_pending = false;
        return true;
    }
    return false;
}

pub fn consumeFlip3dHotkey() bool {
    if (flip3d_hotkey_pending) {
        flip3d_hotkey_pending = false;
        return true;
    }
    return false;
}

pub fn consumeFlip3dDismiss() bool {
    if (flip3d_dismiss_pending) {
        flip3d_dismiss_pending = false;
        return true;
    }
    return false;
}
