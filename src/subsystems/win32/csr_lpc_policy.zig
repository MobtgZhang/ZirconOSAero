// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/csr_lpc_policy.zig
// Purpose: CSRSS/LPC policy helpers shared with host tests (single source for get_message thread id rules).
//
// This is an independent clean-room implementation.
// Reference: docs/cn/DesktopManagerSpec.md §3.3–§3.5 (message queue tid must match user32).

const std = @import("std");

/// `post_message` 载荷最小长度（与 `subsystem.handleApiCall` 中 `d.len >= 32` 一致）：HWND+u32+pad+wparam+lparam。
pub const post_message_payload_min_bytes: usize = 32;

/// `register_window` / `destroy_window` 前导 HWND（小端 u64）。
pub const hwnd_u64_payload_bytes: usize = 8;
/// 与 `subsystem.handleApiCall` 中 `post_message` 缓冲布局一致（小端）：0–8 HWND，8–12 msg，12–16 填充，16–24 wparam，24–32 lparam。
pub const post_message_hwnd_off: usize = 0;
pub const post_message_msg_off: usize = 8;
pub const post_message_wparam_off: usize = 16;
pub const post_message_lparam_off: usize = 24;
/// `get_message`：0–8 hwnd，8–12 min，12–16 max，16–20 remove，20–24 client_tid。
pub const get_message_hwnd_off: usize = 0;
pub const get_message_min_off: usize = 8;
pub const get_message_tid_off: usize = 20;

pub fn validatePostMessagePayloadLen(data_len: usize) bool {
    return data_len >= post_message_payload_min_bytes;
}

/// `get_message` 请求缓冲偏移 20–24 为显式线程 id（小端）。**`0` 为非法**：不得回退为 `pid`，否则与
/// `CreateWindowEx` 登记的 `thread_id` 错配导致「有 HWND 无消息」假阴性。
/// Ref: `subsystem.handleApiCall` / `user32.csrFillOneMessageForLpc`.
pub fn resolveGetMessageClientTid(explicit_tid: u32) ?u32 {
    if (explicit_tid == 0) return null;
    return explicit_tid;
}

/// DWM 监听注册：`register_dwm_listener` 允许 `tid==0` 时回退为 `pid`（与取消息不同，无队列线程对齐要求）。
pub fn resolveDwmListenerTid(explicit_tid: u32, client_pid: u32) u32 {
    if (explicit_tid == 0) return client_pid;
    return explicit_tid;
}

test "LPC get_message rejects tid 0" {
    try std.testing.expect(resolveGetMessageClientTid(0) == null);
    try std.testing.expectEqual(@as(u32, 9), resolveGetMessageClientTid(9).?);
}

test "post_message payload length guard matches subsystem" {
    try std.testing.expect(validatePostMessagePayloadLen(post_message_payload_min_bytes));
    try std.testing.expect(!validatePostMessagePayloadLen(post_message_payload_min_bytes - 1));
}

test "Dwm listener tid 0 falls back to pid" {
    try std.testing.expectEqual(@as(u32, 42), resolveDwmListenerTid(0, 42));
    try std.testing.expectEqual(@as(u32, 7), resolveDwmListenerTid(7, 42));
}

test "LPC payload offsets align with subsystem handleApiCall" {
    try std.testing.expect(post_message_wparam_off >= post_message_msg_off + 4);
    try std.testing.expect(get_message_tid_off == 20);
}
