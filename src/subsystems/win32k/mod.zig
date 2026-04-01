// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32k/mod.zig
// Purpose: Win32k-style window server scaffold (HWND, Z-order, minimal message queue).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/winmsg/window-features
// Reference: https://learn.microsoft.com/windows/win32/winmsg/about-messages-and-message-queues

const std = @import("std");

pub const HWND = usize;

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Minimal window record for future kernel-side win32k (Phase C/F).
pub const Window = struct {
    hwnd: HWND,
    parent: ?HWND,
    rect: Rect,
    z_order: i32,
    visible: bool,
};

pub const WM_NULL: u32 = 0x0000;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_INPUT: u32 = 0x00FF;

pub const MSG = struct {
    hwnd: HWND,
    message: u32,
    wparam: usize,
    lparam: isize,
};

var next_hwnd: HWND = 0x1000;

pub fn allocHwnd() HWND {
    const h = next_hwnd;
    next_hwnd +|= 1;
    return h;
}

const max_windows = 32;
var win_store: [max_windows]Window = undefined;
var win_len: usize = 0;

/// Register a window in the in-kernel table (single-threaded desktop; no real win32k session yet).
pub fn windowAttach(w: Window) bool {
    if (win_len >= max_windows) return false;
    win_store[win_len] = w;
    win_len += 1;
    return true;
}

pub fn windowCreateSimple(rect: Rect) ?HWND {
    const hwnd = allocHwnd();
    if (!windowAttach(.{
        .hwnd = hwnd,
        .parent = null,
        .rect = rect,
        .z_order = @intCast(win_len),
        .visible = true,
    })) return null;
    return hwnd;
}

pub fn windowCount() usize {
    return win_len;
}

pub fn findWindow(hwnd: HWND) ?*Window {
    var i: usize = 0;
    while (i < win_len) : (i += 1) {
        if (win_store[i].hwnd == hwnd) return &win_store[i];
    }
    return null;
}

/// Raise window above others (naive: max z_order + 1).
pub fn setForegroundZOrder(hwnd: HWND) bool {
    const wp = findWindow(hwnd) orelse return false;
    var max_z: i32 = wp.z_order;
    var i: usize = 0;
    while (i < win_len) : (i += 1) {
        max_z = @max(max_z, win_store[i].z_order);
    }
    wp.z_order = max_z + 1;
    return true;
}

fn lessZ(_: void, a: Window, b: Window) bool {
    return a.z_order < b.z_order;
}

/// Fills `out` with HWNDs sorted by ascending z_order (back-to-front). Returns count written.
pub fn hwndsByZOrderAsc(out: []HWND) usize {
    if (win_len == 0) return 0;
    var tmp: [max_windows]Window = undefined;
    @memcpy(tmp[0..win_len], win_store[0..win_len]);
    std.sort.pdq(Window, tmp[0..win_len], {}, lessZ);
    const n = @min(out.len, win_len);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        out[k] = tmp[k].hwnd;
    }
    return n;
}

const msg_cap = 64;
var msg_ring: [msg_cap]MSG = undefined;
var msg_r: usize = 0;
var msg_w: usize = 0;
var msg_count: usize = 0;

pub fn postMessage(hwnd_v: HWND, msg: u32, wparam: usize, lparam: isize) bool {
    if (msg_count >= msg_cap) return false;
    msg_ring[msg_w] = .{
        .hwnd = hwnd_v,
        .message = msg,
        .wparam = wparam,
        .lparam = lparam,
    };
    msg_w = (msg_w + 1) % msg_cap;
    msg_count += 1;
    return true;
}

/// Non-blocking dequeue (kernel demo path). Returns false if empty.
pub fn peekMessage(out: *MSG) bool {
    if (msg_count == 0) return false;
    out.* = msg_ring[msg_r];
    msg_r = (msg_r + 1) % msg_cap;
    msg_count -= 1;
    return true;
}

pub fn pendingMessageCount() usize {
    return msg_count;
}

test "win32k hwnd allocation" {
    const a = allocHwnd();
    const b = allocHwnd();
    try std.testing.expect(a != b);
}

test "win32k z-order and messages" {
    win_len = 0;
    msg_count = 0;
    msg_r = 0;
    msg_w = 0;
    next_hwnd = 0x1000;

    const h_opt = windowCreateSimple(.{ .left = 0, .top = 0, .right = 10, .bottom = 10 });
    try std.testing.expect(h_opt != null);
    const h = h_opt.?;
    _ = setForegroundZOrder(h);
    var ord: [8]HWND = undefined;
    const n = hwndsByZOrderAsc(&ord);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(h, ord[0]);

    try std.testing.expect(postMessage(h, WM_PAINT, 0, 0));
    var m: MSG = undefined;
    try std.testing.expect(peekMessage(&m));
    try std.testing.expectEqual(h, m.hwnd);
    try std.testing.expectEqual(WM_PAINT, m.message);
}
