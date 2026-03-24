//! Linux evdev 风格键码（VirtIO-Input）→ 字符环与 Ctrl+Shift+Esc 任务管理器热键。
//! 供 LoongArch（无 PS/2）与 `kbd.zig` / `arch.readInputChar` 使用。

const RING_CAP: usize = 128;

var ring: [RING_CAP]u8 = undefined;
var ring_head: usize = 0;
var ring_tail: usize = 0;

var left_ctrl: bool = false;
var left_shift: bool = false;
var right_shift: bool = false;
var taskmgr_hotkey_pending: bool = false;

// input-event-codes.h（节选）
const KEY_ESC: u16 = 1;
const KEY_1: u16 = 2;
const KEY_9: u16 = 10;
const KEY_0: u16 = 11;
const KEY_MINUS: u16 = 12;
const KEY_EQUAL: u16 = 13;
const KEY_BACKSPACE: u16 = 14;
const KEY_TAB: u16 = 15;
const KEY_ENTER: u16 = 28;
const KEY_LEFTCTRL: u16 = 29;
const KEY_A: u16 = 30;
const KEY_Z: u16 = 45;
const KEY_LEFTSHIFT: u16 = 42;
const KEY_RIGHTSHIFT: u16 = 54;
const KEY_LEFTALT: u16 = 56;
const KEY_SPACE: u16 = 57;

fn shiftHeld() bool {
    return left_shift or right_shift;
}

fn pushChar(c: u8) void {
    const next = (ring_tail + 1) % RING_CAP;
    if (next == ring_head) return;
    ring[ring_tail] = c;
    ring_tail = next;
}

pub fn readChar() ?u8 {
    if (ring_head == ring_tail) return null;
    const c = ring[ring_head];
    ring_head = (ring_head + 1) % RING_CAP;
    return c;
}

pub fn hasData() bool {
    return ring_head != ring_tail;
}

pub fn consumeTaskMgrHotkey() bool {
    if (taskmgr_hotkey_pending) {
        taskmgr_hotkey_pending = false;
        return true;
    }
    return false;
}

fn mapLetter(code: u16, press: bool) void {
    if (!press) return;
    if (code < KEY_A or code > KEY_Z) return;
    var c: u8 = @truncate('a' + (code - KEY_A));
    if (shiftHeld()) {
        if (c >= 'a' and c <= 'z') c -= 32;
    }
    pushChar(c);
}

fn mapDigitRow(code: u16, press: bool) void {
    if (!press) return;
    const sh = shiftHeld();
    if (code >= KEY_1 and code <= KEY_9) {
        pushChar(@truncate('1' + (code - KEY_1)));
        return;
    }
    if (code == KEY_0) {
        pushChar('0');
        return;
    }
    switch (code) {
        KEY_MINUS => pushChar(if (sh) '_' else '-'),
        KEY_EQUAL => pushChar(if (sh) '+' else '='),
        else => {},
    }
}

/// 由 VirtIO-Input `EV_KEY` 路径调用（`val`：0 释放，非 0 按下）
pub fn handleEvKey(code: u16, val: i32) void {
    const press = val != 0;
    switch (code) {
        KEY_LEFTCTRL => left_ctrl = press,
        KEY_LEFTSHIFT => left_shift = press,
        KEY_RIGHTSHIFT => right_shift = press,
        KEY_ESC => {
            if (press and left_ctrl and shiftHeld()) {
                taskmgr_hotkey_pending = true;
            }
        },
        KEY_ENTER => {
            if (press) pushChar('\n');
        },
        KEY_BACKSPACE => {
            if (press) pushChar(0x08);
        },
        KEY_TAB => {
            if (press) pushChar('\t');
        },
        KEY_SPACE => {
            if (press) pushChar(' ');
        },
        else => {
            mapLetter(code, press);
            mapDigitRow(code, press);
        },
    }
}
