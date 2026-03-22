//! user32 - Win32 User Interface API Subset
//! Phase 10: Window management, message queue, window classes,
//! message loop, input processing, and basic UI primitives.

const klog = @import("../../rtl/klog.zig");
const kernel32 = @import("../../libs/kernel32.zig");
const console_mod = @import("console.zig");
const subsystem = @import("subsystem.zig");

pub const BOOL = kernel32.BOOL;
pub const TRUE = kernel32.TRUE;
pub const FALSE = kernel32.FALSE;
pub const DWORD = kernel32.DWORD;
pub const WORD = kernel32.WORD;
pub const HANDLE = kernel32.HANDLE;

pub const HWND = u64;
pub const HMENU = u64;
pub const HICON = u64;
pub const HCURSOR = u64;
pub const HBRUSH = u64;
pub const HDC = u64;
pub const HINSTANCE = u64;
pub const WPARAM = u64;
pub const LPARAM = i64;
pub const LRESULT = i64;
pub const ATOM = u16;

pub const HWND_TOP: HWND = 0;
pub const HWND_BOTTOM: HWND = 1;
pub const HWND_TOPMOST: HWND = 0xFFFFFFFFFFFFFFFE;
pub const HWND_NOTOPMOST: HWND = 0xFFFFFFFFFFFFFFFD;
pub const HWND_DESKTOP: HWND = 0;

// ── Window Styles ──

pub const WS_OVERLAPPED: DWORD = 0x00000000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_MINIMIZE: DWORD = 0x20000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_DISABLED: DWORD = 0x08000000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_BORDER: DWORD = 0x00800000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_OVERLAPPEDWINDOW: DWORD = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU |
    WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

pub const WS_EX_TOPMOST: DWORD = 0x00000008;
pub const WS_EX_ACCEPTFILES: DWORD = 0x00000010;
pub const WS_EX_TRANSPARENT: DWORD = 0x00000020;
pub const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
pub const WS_EX_WINDOWEDGE: DWORD = 0x00000100;
pub const WS_EX_CLIENTEDGE: DWORD = 0x00000200;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;

// ── Window Messages ──

pub const WM_NULL: u32 = 0x0000;
pub const WM_CREATE: u32 = 0x0001;
pub const WM_DESTROY: u32 = 0x0002;
pub const WM_MOVE: u32 = 0x0003;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_ACTIVATE: u32 = 0x0006;
pub const WM_SETFOCUS: u32 = 0x0007;
pub const WM_KILLFOCUS: u32 = 0x0008;
pub const WM_ENABLE: u32 = 0x000A;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_QUIT: u32 = 0x0012;
pub const WM_SHOWWINDOW: u32 = 0x0018;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_CHAR: u32 = 0x0102;
pub const WM_COMMAND: u32 = 0x0111;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_RBUTTONDOWN: u32 = 0x0204;
pub const WM_RBUTTONUP: u32 = 0x0205;
pub const WM_USER: u32 = 0x0400;
pub const WM_APP: u32 = 0x8000;

// ── Show Window Commands ──

pub const SW_HIDE: u32 = 0;
pub const SW_SHOWNORMAL: u32 = 1;
pub const SW_SHOWMINIMIZED: u32 = 2;
pub const SW_SHOWMAXIMIZED: u32 = 3;
pub const SW_SHOW: u32 = 5;
pub const SW_MINIMIZE: u32 = 6;
pub const SW_RESTORE: u32 = 9;

// ── System Metrics ──

pub const SM_CXSCREEN: u32 = 0;
pub const SM_CYSCREEN: u32 = 1;
pub const SM_CXFULLSCREEN: u32 = 16;
pub const SM_CYFULLSCREEN: u32 = 17;

// ── MessageBox Styles ──

pub const MB_OK: u32 = 0x00000000;
pub const MB_OKCANCEL: u32 = 0x00000001;
pub const MB_YESNOCANCEL: u32 = 0x00000003;
pub const MB_YESNO: u32 = 0x00000004;
pub const MB_ICONERROR: u32 = 0x00000010;
pub const MB_ICONQUESTION: u32 = 0x00000020;
pub const MB_ICONWARNING: u32 = 0x00000030;
pub const MB_ICONINFORMATION: u32 = 0x00000040;

pub const IDOK: u32 = 1;
pub const IDCANCEL: u32 = 2;
pub const IDYES: u32 = 6;
pub const IDNO: u32 = 7;

// ── Color Constants ──

pub const COLOR_WINDOW: u32 = 5;
pub const COLOR_WINDOWFRAME: u32 = 6;
pub const COLOR_WINDOWTEXT: u32 = 8;
pub const COLOR_BTNFACE: u32 = 15;
pub const COLOR_DESKTOP: u32 = 1;

// ── Cursor Constants ──

pub const IDC_ARROW: u32 = 32512;
pub const IDC_IBEAM: u32 = 32513;
pub const IDC_WAIT: u32 = 32514;
pub const IDC_CROSS: u32 = 32515;
pub const IDC_HAND: u32 = 32649;

// ── Structures ──

pub const POINT = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const SIZE = struct {
    cx: i32 = 0,
    cy: i32 = 0,
};

pub const RECT = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(self: *const RECT) i32 {
        return self.right - self.left;
    }

    pub fn height(self: *const RECT) i32 {
        return self.bottom - self.top;
    }
};

pub const MSG = struct {
    hwnd: HWND = 0,
    message: u32 = 0,
    wparam: WPARAM = 0,
    lparam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
};

pub const WNDCLASSA = struct {
    style: u32 = 0,
    wndproc_id: u32 = 0,
    cls_extra: i32 = 0,
    wnd_extra: i32 = 0,
    instance: HINSTANCE = 0,
    icon: HICON = 0,
    cursor: HCURSOR = 0,
    background: HBRUSH = 0,
    menu_name: [64]u8 = [_]u8{0} ** 64,
    menu_name_len: usize = 0,
    class_name: [64]u8 = [_]u8{0} ** 64,
    class_name_len: usize = 0,
};

pub const WNDCLASSEXA = struct {
    cb_size: u32 = @sizeOf(WNDCLASSEXA),
    style: u32 = 0,
    wndproc_id: u32 = 0,
    cls_extra: i32 = 0,
    wnd_extra: i32 = 0,
    instance: HINSTANCE = 0,
    icon: HICON = 0,
    cursor: HCURSOR = 0,
    background: HBRUSH = 0,
    menu_name: [64]u8 = [_]u8{0} ** 64,
    menu_name_len: usize = 0,
    class_name: [64]u8 = [_]u8{0} ** 64,
    class_name_len: usize = 0,
    icon_sm: HICON = 0,
};

pub const PAINTSTRUCT = struct {
    hdc: HDC = 0,
    erase: BOOL = TRUE,
    paint_rect: RECT = .{},
    restore: BOOL = FALSE,
    inc_update: BOOL = FALSE,
    reserved: [32]u8 = [_]u8{0} ** 32,
};

pub const CREATESTRUCTA = struct {
    create_params: u64 = 0,
    instance: HINSTANCE = 0,
    menu: HMENU = 0,
    parent: HWND = 0,
    cy: i32 = 0,
    cx: i32 = 0,
    y: i32 = 0,
    x: i32 = 0,
    style: DWORD = 0,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    class_name: [64]u8 = [_]u8{0} ** 64,
    class_name_len: usize = 0,
    ex_style: DWORD = 0,
};

// ── Internal Window Object ──

const MAX_WINDOWS: usize = 64;
const MAX_WINDOW_CLASSES: usize = 32;
const MAX_MSG_QUEUE: usize = 128;

const Window = struct {
    hwnd: HWND = 0,
    is_valid: bool = false,
    is_visible: bool = false,
    is_enabled: bool = false,
    is_minimized: bool = false,
    is_maximized: bool = false,
    style: DWORD = 0,
    ex_style: DWORD = 0,
    class_id: u32 = 0,
    owner_pid: u32 = 0,
    parent: HWND = 0,
    rect: RECT = .{},
    client_rect: RECT = .{},
    title: [128]u8 = [_]u8{0} ** 128,
    title_len: usize = 0,
    instance: HINSTANCE = 0,
    menu: HMENU = 0,
    user_data: u64 = 0,
    wndproc_id: u32 = 0,
    needs_paint: bool = false,
    msg_queue: [MAX_MSG_QUEUE]MSG = [_]MSG{.{}} ** MAX_MSG_QUEUE,
    msg_head: usize = 0,
    msg_tail: usize = 0,
    msg_count: usize = 0,
    timer_id: u32 = 0,
    timer_interval: u32 = 0,
    timer_ticks: u32 = 0,

    pub fn getTitle(self: *const Window) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn postMessage(self: *Window, msg: u32, wparam: WPARAM, lparam: LPARAM) bool {
        if (self.msg_count >= MAX_MSG_QUEUE) return false;
        self.msg_queue[self.msg_tail] = .{
            .hwnd = self.hwnd,
            .message = msg,
            .wparam = wparam,
            .lparam = lparam,
            .time = kernel32.GetTickCount(),
        };
        self.msg_tail = (self.msg_tail + 1) % MAX_MSG_QUEUE;
        self.msg_count += 1;
        return true;
    }

    pub fn peekMessage(self: *Window) ?MSG {
        if (self.msg_count == 0) return null;
        return self.msg_queue[self.msg_head];
    }

    pub fn getMessage(self: *Window) ?MSG {
        if (self.msg_count == 0) return null;
        const msg = self.msg_queue[self.msg_head];
        self.msg_head = (self.msg_head + 1) % MAX_MSG_QUEUE;
        self.msg_count -= 1;
        return msg;
    }
};

const WindowClass = struct {
    is_registered: bool = false,
    style: u32 = 0,
    class_name: [64]u8 = [_]u8{0} ** 64,
    class_name_len: usize = 0,
    wndproc_id: u32 = 0,
    background: HBRUSH = 0,
    cursor: HCURSOR = 0,
    icon: HICON = 0,
    instance: HINSTANCE = 0,
    atom: ATOM = 0,

    pub fn getName(self: *const WindowClass) []const u8 {
        return self.class_name[0..self.class_name_len];
    }
};

// ── Global State ──

var windows: [MAX_WINDOWS]Window = [_]Window{.{}} ** MAX_WINDOWS;
var window_count: usize = 0;
var next_hwnd: HWND = 0x10000;

var window_classes: [MAX_WINDOW_CLASSES]WindowClass = [_]WindowClass{.{}} ** MAX_WINDOW_CLASSES;
var class_count: usize = 0;
var next_atom: ATOM = 0xC000;

var focus_hwnd: HWND = 0;
var capture_hwnd: HWND = 0;
var active_hwnd: HWND = 0;
var foreground_hwnd: HWND = 0;

var screen_width: i32 = 800;
var screen_height: i32 = 600;

var user32_initialized: bool = false;
var total_messages_processed: u64 = 0;
var total_windows_created: u64 = 0;

// ── Window Class Registration ──

pub fn RegisterClassA(wc: *const WNDCLASSA) ATOM {
    if (class_count >= MAX_WINDOW_CLASSES) return 0;

    var cls = &window_classes[class_count];
    cls.* = .{};
    cls.is_registered = true;
    cls.style = wc.style;
    cls.wndproc_id = wc.wndproc_id;
    cls.background = wc.background;
    cls.cursor = wc.cursor;
    cls.icon = wc.icon;
    cls.instance = wc.instance;

    const n = @min(wc.class_name_len, cls.class_name.len);
    @memcpy(cls.class_name[0..n], wc.class_name[0..n]);
    cls.class_name_len = n;

    cls.atom = next_atom;
    next_atom += 1;
    class_count += 1;

    klog.debug("user32: RegisterClass '%s' -> atom=%u", .{ cls.getName(), cls.atom });
    return cls.atom;
}

pub fn RegisterClassExA(wc: *const WNDCLASSEXA) ATOM {
    var simple: WNDCLASSA = .{};
    simple.style = wc.style;
    simple.wndproc_id = wc.wndproc_id;
    simple.cls_extra = wc.cls_extra;
    simple.wnd_extra = wc.wnd_extra;
    simple.instance = wc.instance;
    simple.icon = wc.icon;
    simple.cursor = wc.cursor;
    simple.background = wc.background;
    @memcpy(&simple.class_name, &wc.class_name);
    simple.class_name_len = wc.class_name_len;
    return RegisterClassA(&simple);
}

pub fn UnregisterClassA(class_name: []const u8, _: HINSTANCE) BOOL {
    for (window_classes[0..class_count]) |*cls| {
        if (cls.is_registered and strEqlI(cls.getName(), class_name)) {
            cls.is_registered = false;
            return TRUE;
        }
    }
    return FALSE;
}

fn findClass(class_name: []const u8) ?*WindowClass {
    for (window_classes[0..class_count]) |*cls| {
        if (cls.is_registered and strEqlI(cls.getName(), class_name)) return cls;
    }
    return null;
}

// ── Window Creation/Destruction ──

pub const CW_USEDEFAULT: i32 = @as(i32, @bitCast(@as(u32, 0x80000000)));

pub fn CreateWindowExA(
    ex_style: DWORD,
    class_name: []const u8,
    window_name: []const u8,
    style: DWORD,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: HWND,
    menu: HMENU,
    instance: HINSTANCE,
    _: u64,
) HWND {
    if (window_count >= MAX_WINDOWS) return 0;

    const cls = findClass(class_name);
    const cls_id: u32 = if (cls) |c| c.atom else 0;

    var wnd = &windows[window_count];
    wnd.* = .{};
    wnd.hwnd = next_hwnd;
    wnd.is_valid = true;
    wnd.style = style;
    wnd.ex_style = ex_style;
    wnd.class_id = cls_id;
    wnd.parent = parent;
    wnd.instance = instance;
    wnd.menu = menu;
    wnd.owner_pid = kernel32.GetCurrentProcessId();

    if (cls) |c| {
        wnd.wndproc_id = c.wndproc_id;
    }

    const actual_x = if (x == CW_USEDEFAULT) @as(i32, 100) else x;
    const actual_y = if (y == CW_USEDEFAULT) @as(i32, 100) else y;
    const actual_w = if (width == CW_USEDEFAULT) @as(i32, 640) else width;
    const actual_h = if (height == CW_USEDEFAULT) @as(i32, 480) else height;

    wnd.rect = .{
        .left = actual_x,
        .top = actual_y,
        .right = actual_x + actual_w,
        .bottom = actual_y + actual_h,
    };
    wnd.client_rect = .{
        .left = 0,
        .top = 0,
        .right = actual_w,
        .bottom = actual_h,
    };

    const tn = @min(window_name.len, wnd.title.len);
    @memcpy(wnd.title[0..tn], window_name[0..tn]);
    wnd.title_len = tn;

    next_hwnd += 1;
    window_count += 1;
    total_windows_created += 1;

    _ = wnd.postMessage(WM_CREATE, 0, 0);

    if ((style & WS_VISIBLE) != 0) {
        wnd.is_visible = true;
        _ = wnd.postMessage(WM_SHOWWINDOW, 1, 0);
    }

    klog.debug("user32: CreateWindow '%s' hwnd=0x%x (%dx%d)", .{
        window_name, wnd.hwnd, actual_w, actual_h,
    });

    return wnd.hwnd;
}

pub fn DestroyWindow(hwnd: HWND) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    _ = wnd.postMessage(WM_DESTROY, 0, 0);
    wnd.is_valid = false;
    wnd.is_visible = false;

    if (focus_hwnd == hwnd) focus_hwnd = 0;
    if (active_hwnd == hwnd) active_hwnd = 0;
    if (foreground_hwnd == hwnd) foreground_hwnd = 0;

    return TRUE;
}

// ── Window Properties ──

pub fn ShowWindow(hwnd: HWND, cmd: u32) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    const was_visible = wnd.is_visible;

    switch (cmd) {
        SW_HIDE => wnd.is_visible = false,
        SW_SHOW, SW_SHOWNORMAL, SW_RESTORE => {
            wnd.is_visible = true;
            wnd.is_minimized = false;
            wnd.is_maximized = false;
        },
        SW_SHOWMINIMIZED, SW_MINIMIZE => {
            wnd.is_visible = true;
            wnd.is_minimized = true;
        },
        SW_SHOWMAXIMIZED => {
            wnd.is_visible = true;
            wnd.is_maximized = true;
            wnd.rect = .{ .left = 0, .top = 0, .right = screen_width, .bottom = screen_height };
        },
        else => {},
    }

    _ = wnd.postMessage(WM_SHOWWINDOW, if (wnd.is_visible) 1 else 0, 0);
    return if (was_visible) TRUE else FALSE;
}

pub fn UpdateWindow(hwnd: HWND) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    wnd.needs_paint = true;
    _ = wnd.postMessage(WM_PAINT, 0, 0);
    return TRUE;
}

pub fn EnableWindow(hwnd: HWND, enable: BOOL) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    const was_enabled = wnd.is_enabled;
    wnd.is_enabled = (enable == TRUE);
    _ = wnd.postMessage(WM_ENABLE, if (wnd.is_enabled) 1 else 0, 0);
    return if (!was_enabled) TRUE else FALSE;
}

pub fn IsWindow(hwnd: HWND) BOOL {
    return if (findWindow(hwnd) != null) TRUE else FALSE;
}

pub fn IsWindowVisible(hwnd: HWND) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    return if (wnd.is_visible) TRUE else FALSE;
}

pub fn IsWindowEnabled(hwnd: HWND) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    return if (wnd.is_enabled) TRUE else FALSE;
}

pub fn GetWindowRect(hwnd: HWND, rect: *RECT) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    rect.* = wnd.rect;
    return TRUE;
}

pub fn GetClientRect(hwnd: HWND, rect: *RECT) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    rect.* = wnd.client_rect;
    return TRUE;
}

pub fn SetWindowPos(hwnd: HWND, _: HWND, x: i32, y: i32, cx: i32, cy: i32, _: u32) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    wnd.rect = .{
        .left = x,
        .top = y,
        .right = x + cx,
        .bottom = y + cy,
    };
    wnd.client_rect.right = cx;
    wnd.client_rect.bottom = cy;
    _ = wnd.postMessage(WM_MOVE, 0, 0);
    _ = wnd.postMessage(WM_SIZE, 0, 0);
    return TRUE;
}

pub fn MoveWindow(hwnd: HWND, x: i32, y: i32, width: i32, height: i32, repaint: BOOL) BOOL {
    _ = repaint;
    return SetWindowPos(hwnd, 0, x, y, width, height, 0);
}

pub fn SetWindowTextA(hwnd: HWND, text: []const u8) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    const n = @min(text.len, wnd.title.len);
    @memcpy(wnd.title[0..n], text[0..n]);
    wnd.title_len = n;
    return TRUE;
}

pub fn GetWindowTextA(hwnd: HWND, buffer: []u8) i32 {
    const wnd = findWindow(hwnd) orelse return 0;
    const n = @min(wnd.title_len, buffer.len);
    @memcpy(buffer[0..n], wnd.title[0..n]);
    return @intCast(n);
}

pub fn GetWindowTextLengthA(hwnd: HWND) i32 {
    const wnd = findWindow(hwnd) orelse return 0;
    return @intCast(wnd.title_len);
}

// ── Focus/Active Window ──

pub fn SetFocus(hwnd: HWND) HWND {
    const old = focus_hwnd;
    if (findWindow(hwnd)) |wnd| {
        if (old != hwnd) {
            if (findWindow(old)) |old_wnd| {
                _ = old_wnd.postMessage(WM_KILLFOCUS, hwnd, 0);
            }
            _ = wnd.postMessage(WM_SETFOCUS, old, 0);
        }
        focus_hwnd = hwnd;
    }
    return old;
}

pub fn GetFocus() HWND {
    return focus_hwnd;
}

pub fn SetActiveWindow(hwnd: HWND) HWND {
    const old = active_hwnd;
    if (findWindow(hwnd) != null) {
        active_hwnd = hwnd;
    }
    return old;
}

pub fn GetActiveWindow() HWND {
    return active_hwnd;
}

pub fn SetForegroundWindow(hwnd: HWND) BOOL {
    if (findWindow(hwnd) != null) {
        foreground_hwnd = hwnd;
        return TRUE;
    }
    return FALSE;
}

pub fn GetForegroundWindow() HWND {
    return foreground_hwnd;
}

pub fn GetDesktopWindow() HWND {
    return HWND_DESKTOP;
}

// ── Message Loop ──

pub fn GetMessageA(msg: *MSG, hwnd: HWND, _: u32, _: u32) BOOL {
    if (hwnd != 0) {
        const wnd = findWindow(hwnd) orelse return FALSE;
        if (wnd.getMessage()) |m| {
            msg.* = m;
            total_messages_processed += 1;
            return if (m.message != WM_QUIT) TRUE else FALSE;
        }
    } else {
        for (windows[0..window_count]) |*wnd| {
            if (!wnd.is_valid) continue;
            if (wnd.getMessage()) |m| {
                msg.* = m;
                total_messages_processed += 1;
                return if (m.message != WM_QUIT) TRUE else FALSE;
            }
        }
    }
    msg.* = .{};
    return FALSE;
}

pub fn PeekMessageA(msg: *MSG, hwnd: HWND, _: u32, _: u32, remove: u32) BOOL {
    const PM_REMOVE: u32 = 0x0001;
    if (hwnd != 0) {
        const wnd = findWindow(hwnd) orelse return FALSE;
        if ((remove & PM_REMOVE) != 0) {
            if (wnd.getMessage()) |m| {
                msg.* = m;
                total_messages_processed += 1;
                return TRUE;
            }
        } else {
            if (wnd.peekMessage()) |m| {
                msg.* = m;
                return TRUE;
            }
        }
    }
    return FALSE;
}

pub fn TranslateMessage(_: *const MSG) BOOL {
    return TRUE;
}

pub fn DispatchMessageA(msg: *const MSG) LRESULT {
    total_messages_processed += 1;
    _ = msg;
    return 0;
}

pub fn PostMessageA(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    return if (wnd.postMessage(msg, wparam, lparam)) TRUE else FALSE;
}

pub fn SendMessageA(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) LRESULT {
    _ = PostMessageA(hwnd, msg, wparam, lparam);
    return 0;
}

pub fn PostQuitMessage(exit_code: i32) void {
    for (windows[0..window_count]) |*wnd| {
        if (wnd.is_valid and wnd.owner_pid == kernel32.GetCurrentProcessId()) {
            _ = wnd.postMessage(WM_QUIT, @intCast(@as(u32, @bitCast(exit_code))), 0);
        }
    }
}

// ── Painting ──

pub fn BeginPaint(hwnd: HWND, ps: *PAINTSTRUCT) HDC {
    const wnd = findWindow(hwnd) orelse return 0;
    ps.* = .{};
    ps.paint_rect = wnd.client_rect;
    ps.hdc = hwnd;
    wnd.needs_paint = false;
    return ps.hdc;
}

pub fn EndPaint(hwnd: HWND, _: *const PAINTSTRUCT) BOOL {
    _ = hwnd;
    return TRUE;
}

pub fn InvalidateRect(hwnd: HWND, _: ?*const RECT, _: BOOL) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    wnd.needs_paint = true;
    return TRUE;
}

pub fn GetDC(hwnd: HWND) HDC {
    if (findWindow(hwnd) != null) return hwnd;
    return 0;
}

pub fn ReleaseDC(_: HWND, _: HDC) i32 {
    return 1;
}

// ── Timer ──

pub fn SetTimer(hwnd: HWND, id: u32, interval: u32, _: u64) u32 {
    const wnd = findWindow(hwnd) orelse return 0;
    wnd.timer_id = id;
    wnd.timer_interval = interval;
    wnd.timer_ticks = 0;
    return id;
}

pub fn KillTimer(hwnd: HWND, _: u32) BOOL {
    const wnd = findWindow(hwnd) orelse return FALSE;
    wnd.timer_id = 0;
    wnd.timer_interval = 0;
    return TRUE;
}

// ── System Metrics ──

pub fn GetSystemMetrics(index: u32) i32 {
    return switch (index) {
        SM_CXSCREEN, SM_CXFULLSCREEN => screen_width,
        SM_CYSCREEN, SM_CYFULLSCREEN => screen_height,
        else => 0,
    };
}

// ── Message Box ──

pub fn MessageBoxA(_: HWND, text: []const u8, caption: []const u8, mb_type: u32) u32 {
    klog.info("MessageBox: [%s] %s (type=0x%x)", .{ caption, text, mb_type });

    if ((mb_type & 0x0F) == MB_OK) return IDOK;
    if ((mb_type & 0x0F) == MB_OKCANCEL) return IDOK;
    if ((mb_type & 0x0F) == MB_YESNO) return IDYES;
    if ((mb_type & 0x0F) == MB_YESNOCANCEL) return IDYES;
    return IDOK;
}

// ── Mouse Capture ──

pub fn SetCapture(hwnd: HWND) HWND {
    const old = capture_hwnd;
    if (findWindow(hwnd) != null) capture_hwnd = hwnd;
    return old;
}

pub fn ReleaseCapture() BOOL {
    capture_hwnd = 0;
    return TRUE;
}

pub fn GetCapture() HWND {
    return capture_hwnd;
}

// ── Misc ──

pub fn GetParent(hwnd: HWND) HWND {
    const wnd = findWindow(hwnd) orelse return 0;
    return wnd.parent;
}

pub fn SetWindowLongA(hwnd: HWND, index: i32, value: u64) u64 {
    const wnd = findWindow(hwnd) orelse return 0;
    const GWL_USERDATA: i32 = -21;
    const GWL_STYLE: i32 = -16;
    const GWL_EXSTYLE: i32 = -20;

    return switch (index) {
        GWL_USERDATA => blk: {
            const old = wnd.user_data;
            wnd.user_data = value;
            break :blk old;
        },
        GWL_STYLE => blk: {
            const old = wnd.style;
            wnd.style = @intCast(value & 0xFFFFFFFF);
            break :blk old;
        },
        GWL_EXSTYLE => blk: {
            const old = wnd.ex_style;
            wnd.ex_style = @intCast(value & 0xFFFFFFFF);
            break :blk old;
        },
        else => 0,
    };
}

pub fn GetWindowLongA(hwnd: HWND, index: i32) u64 {
    const wnd = findWindow(hwnd) orelse return 0;
    const GWL_USERDATA: i32 = -21;
    const GWL_STYLE: i32 = -16;
    const GWL_EXSTYLE: i32 = -20;

    return switch (index) {
        GWL_USERDATA => wnd.user_data,
        GWL_STYLE => wnd.style,
        GWL_EXSTYLE => wnd.ex_style,
        else => 0,
    };
}

pub fn DefWindowProcA(_: HWND, msg: u32, _: WPARAM, _: LPARAM) LRESULT {
    switch (msg) {
        WM_CLOSE => return 0,
        WM_DESTROY => return 0,
        WM_PAINT => return 0,
        else => return 0,
    }
}

pub fn LoadCursorA(_: HINSTANCE, _: u32) HCURSOR {
    return 1;
}

pub fn LoadIconA(_: HINSTANCE, _: u32) HICON {
    return 1;
}

// ── Helpers ──

fn findWindow(hwnd: HWND) ?*Window {
    for (windows[0..window_count]) |*wnd| {
        if (wnd.hwnd == hwnd and wnd.is_valid) return wnd;
    }
    return null;
}

fn strEqlI(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const ax = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const by = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (ax != by) return false;
    }
    return true;
}

// ── Statistics ──

pub fn getWindowCount() usize {
    var count: usize = 0;
    for (windows[0..window_count]) |*wnd| {
        if (wnd.is_valid) count += 1;
    }
    return count;
}

pub fn getClassCount() usize {
    return class_count;
}

pub fn getTotalMessagesProcessed() u64 {
    return total_messages_processed;
}

pub fn getTotalWindowsCreated() u64 {
    return total_windows_created;
}

// ── Demo ──

pub fn runGuiDemo() void {
    klog.info("user32: --- GUI Subsystem Demo ---", .{});

    var wc: WNDCLASSA = .{};
    const cls_name = "ZirconMainWindow";
    @memcpy(wc.class_name[0..cls_name.len], cls_name);
    wc.class_name_len = cls_name.len;
    wc.background = COLOR_WINDOW + 1;
    wc.cursor = IDC_ARROW;
    const atom = RegisterClassA(&wc);
    klog.info("user32: RegisterClass 'ZirconMainWindow' atom=%u", .{atom});

    const hwnd = CreateWindowExA(
        0,
        cls_name,
        "ZirconOS - Main Window",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        0,
        0,
        0,
        0,
    );
    klog.info("user32: CreateWindow hwnd=0x%x", .{hwnd});

    _ = ShowWindow(hwnd, SW_SHOWNORMAL);
    _ = UpdateWindow(hwnd);
    _ = SetFocus(hwnd);

    const notepad_hwnd = CreateWindowExA(
        0,
        cls_name,
        "Untitled - Notepad",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        150,
        150,
        500,
        400,
        0,
        0,
        0,
        0,
    );
    klog.info("user32: Notepad window hwnd=0x%x", .{notepad_hwnd});

    _ = MessageBoxA(hwnd, "ZirconOS GUI subsystem initialized!", "ZirconOS", MB_OK | MB_ICONINFORMATION);

    var msg: MSG = .{};
    var processed: u32 = 0;
    while (processed < 5) {
        if (GetMessageA(&msg, 0, 0, 0) == TRUE) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageA(&msg);
            processed += 1;
        } else break;
    }

    _ = DestroyWindow(notepad_hwnd);
    _ = DestroyWindow(hwnd);

    klog.info("user32: Demo complete: %u windows, %u messages processed", .{
        getWindowCount(), getTotalMessagesProcessed(),
    });
}

// ── Initialization ──

pub fn init() void {
    window_count = 0;
    class_count = 0;
    next_hwnd = 0x10000;
    next_atom = 0xC000;
    focus_hwnd = 0;
    active_hwnd = 0;
    foreground_hwnd = 0;
    capture_hwnd = 0;
    total_messages_processed = 0;
    total_windows_created = 0;
    user32_initialized = true;

    klog.info("user32: Win32 User Interface API initialized", .{});
    klog.info("user32: Window APIs: CreateWindowEx, DestroyWindow, ShowWindow, MoveWindow", .{});
    klog.info("user32: Message APIs: GetMessage, PeekMessage, PostMessage, DispatchMessage", .{});
    klog.info("user32: Paint APIs: BeginPaint, EndPaint, InvalidateRect, GetDC", .{});
    klog.info("user32: Input APIs: SetFocus, SetCapture, SetTimer, MessageBox", .{});
    klog.info("user32: Screen: %ux%u", .{@as(u32, @intCast(screen_width)), @as(u32, @intCast(screen_height))});
}
