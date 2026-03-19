//! Input - ZirconOS Aero Input Handling
//! Manages keyboard hotkeys, mouse cursor state, and global
//! input dispatch. Provides registration for shell hotkeys
//! (Win+D, Win+E, Win+L, Alt+F4, etc.) and tracks modifier
//! key state for combo detection.
//! Reference: ReactOS user32 input handling (win32ss/user/user32/)

pub const MAX_HOTKEYS: usize = 32;
pub const MAX_CURSOR_TYPES: usize = 12;

pub const ModifierFlags = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    win: bool = false,
};

pub const HotkeyEntry = struct {
    vk_code: u8 = 0,
    modifiers: ModifierFlags = .{},
    callback: ?*const fn () void = null,
    is_active: bool = false,
    id: u32 = 0,
};

pub const CursorType = enum(u8) {
    arrow = 0,
    hand = 1,
    ibeam = 2,
    wait_ = 3,
    crosshair = 4,
    size_ns = 5,
    size_ew = 6,
    size_nwse = 7,
    size_nesw = 8,
    move = 9,
    no = 10,
    app_starting = 11,
};

pub const MouseState = struct {
    x: i32 = 0,
    y: i32 = 0,
    left_down: bool = false,
    right_down: bool = false,
    middle_down: bool = false,
    cursor: CursorType = .arrow,
    last_click_x: i32 = 0,
    last_click_y: i32 = 0,
    last_click_tick: u64 = 0,
    double_click_threshold: u64 = 500,
    drag_start_x: i32 = 0,
    drag_start_y: i32 = 0,
    is_dragging: bool = false,
    drag_threshold: i32 = 4,
};

pub const KeyboardState = struct {
    modifiers: ModifierFlags = .{},
    caps_lock: bool = false,
    num_lock: bool = true,
    scroll_lock: bool = false,
    last_key: u8 = 0,
    repeat_count: u32 = 0,
};

var hotkeys: [MAX_HOTKEYS]HotkeyEntry = [_]HotkeyEntry{.{}} ** MAX_HOTKEYS;
var hotkey_count: usize = 0;
var next_hotkey_id: u32 = 1;

var mouse: MouseState = .{};
var keyboard: KeyboardState = .{};
var input_initialized: bool = false;
var input_tick: u64 = 0;

pub fn init() void {
    hotkey_count = 0;
    next_hotkey_id = 1;
    mouse = .{};
    keyboard = .{};
    input_tick = 0;
    input_initialized = true;
}

pub fn registerHotkey(vk_code: u8, modifiers: ModifierFlags, callback: *const fn () void) u32 {
    if (hotkey_count >= MAX_HOTKEYS) return 0;

    const id = next_hotkey_id;
    next_hotkey_id += 1;

    hotkeys[hotkey_count] = .{
        .vk_code = vk_code,
        .modifiers = modifiers,
        .callback = callback,
        .is_active = true,
        .id = id,
    };
    hotkey_count += 1;
    return id;
}

pub fn unregisterHotkey(id: u32) bool {
    var i: usize = 0;
    while (i < hotkey_count) {
        if (hotkeys[i].id == id) {
            var j = i;
            while (j + 1 < hotkey_count) : (j += 1) {
                hotkeys[j] = hotkeys[j + 1];
            }
            hotkeys[hotkey_count - 1] = .{};
            hotkey_count -= 1;
            return true;
        }
        i += 1;
    }
    return false;
}

pub fn processKeyDown(vk_code: u8) bool {
    updateModifiers(vk_code, true);
    keyboard.last_key = vk_code;

    for (hotkeys[0..hotkey_count]) |*hk| {
        if (!hk.is_active) continue;
        if (hk.vk_code == vk_code and modifiersMatch(hk.modifiers, keyboard.modifiers)) {
            if (hk.callback) |cb| {
                cb();
                return true;
            }
        }
    }
    return false;
}

pub fn processKeyUp(vk_code: u8) void {
    updateModifiers(vk_code, false);
}

pub fn processMouseMove(x: i32, y: i32) void {
    mouse.x = x;
    mouse.y = y;

    if (mouse.left_down and !mouse.is_dragging) {
        const dx = x - mouse.drag_start_x;
        const dy = y - mouse.drag_start_y;
        if (dx * dx + dy * dy > mouse.drag_threshold * mouse.drag_threshold) {
            mouse.is_dragging = true;
        }
    }
}

pub fn processMouseDown(button: u8, x: i32, y: i32) bool {
    mouse.x = x;
    mouse.y = y;

    switch (button) {
        0 => {
            mouse.left_down = true;
            mouse.drag_start_x = x;
            mouse.drag_start_y = y;

            const is_double = isDoubleClick(x, y);
            mouse.last_click_x = x;
            mouse.last_click_y = y;
            mouse.last_click_tick = input_tick;
            return is_double;
        },
        1 => {
            mouse.right_down = true;
        },
        2 => {
            mouse.middle_down = true;
        },
        else => {},
    }
    return false;
}

pub fn processMouseUp(button: u8, x: i32, y: i32) void {
    mouse.x = x;
    mouse.y = y;

    switch (button) {
        0 => {
            mouse.left_down = false;
            mouse.is_dragging = false;
        },
        1 => mouse.right_down = false,
        2 => mouse.middle_down = false,
        else => {},
    }
}

pub fn setCursor(cursor_type: CursorType) void {
    mouse.cursor = cursor_type;
}

pub fn getCursor() CursorType {
    return mouse.cursor;
}

pub fn getMouseState() *const MouseState {
    return &mouse;
}

pub fn getKeyboardState() *const KeyboardState {
    return &keyboard;
}

pub fn getModifiers() ModifierFlags {
    return keyboard.modifiers;
}

pub fn isKeyDown(vk_code: u8) bool {
    return keyboard.last_key == vk_code;
}

pub fn tick() void {
    input_tick += 1;
}

pub fn getHotkeyCount() usize {
    return hotkey_count;
}

fn updateModifiers(vk_code: u8, down: bool) void {
    switch (vk_code) {
        0x11 => keyboard.modifiers.ctrl = down,
        0x12 => keyboard.modifiers.alt = down,
        0x10 => keyboard.modifiers.shift = down,
        0x5B, 0x5C => keyboard.modifiers.win = down,
        0x14 => if (down) {
            keyboard.caps_lock = !keyboard.caps_lock;
        },
        0x90 => if (down) {
            keyboard.num_lock = !keyboard.num_lock;
        },
        else => {},
    }
}

fn modifiersMatch(required: ModifierFlags, current: ModifierFlags) bool {
    return required.ctrl == current.ctrl and
        required.alt == current.alt and
        required.shift == current.shift and
        required.win == current.win;
}

fn isDoubleClick(x: i32, y: i32) bool {
    if (input_tick - mouse.last_click_tick > mouse.double_click_threshold) return false;
    const dx = x - mouse.last_click_x;
    const dy = y - mouse.last_click_y;
    return dx * dx + dy * dy <= 16;
}

pub fn cursorForHitTest(hit: u8) CursorType {
    return switch (hit) {
        10 => .size_ew,
        11 => .size_ew,
        12 => .size_ns,
        13 => .size_ns,
        14 => .size_nwse,
        15 => .size_nesw,
        16 => .size_nesw,
        17 => .size_nwse,
        2 => .arrow,
        else => .arrow,
    };
}
