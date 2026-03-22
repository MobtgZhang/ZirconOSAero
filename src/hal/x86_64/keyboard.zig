//! PS/2 Keyboard Driver
//! Translates scan code set 1 to ASCII characters
//! Uses a ring buffer to queue keypresses for the shell

const portio = @import("portio.zig");

const KB_DATA_PORT: u16 = 0x60;
const KB_STATUS_PORT: u16 = 0x64;

const RING_SIZE: usize = 128;

var ring_buf: [RING_SIZE]u8 = [_]u8{0} ** RING_SIZE;
var ring_head: usize = 0;
var ring_tail: usize = 0;
var shift_held: bool = false;
var ctrl_held: bool = false;
var caps_lock: bool = false;
var initialized: bool = false;

/// Ctrl+Shift+Esc → Task Manager (desktop shell; consumed via `consumeTaskMgrHotkey`)
var taskmgr_hotkey_pending: bool = false;

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

/// Process one PS/2 scan code (also used when draining the 8042 buffer from the mouse poll path).
pub fn handleScancodeByte(scancode: u8) void {
    if (scancode & 0x80 != 0) {
        const released = scancode & 0x7F;
        if (released == 0x2A or released == 0x36) shift_held = false;
        if (released == 0x1D) ctrl_held = false;
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
    if (scancode == 0x3A) {
        caps_lock = !caps_lock;
        return;
    }

    // Esc (make code 0x01): Task Manager shortcut when Ctrl+Shift held
    if (scancode == 0x01 and ctrl_held and shift_held) {
        taskmgr_hotkey_pending = true;
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
