// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/csr_lpc_policy.zig
// Purpose: CSRSS/LPC policy helpers shared with host tests (single source for get_message thread id rules).
//
// This is an independent clean-room implementation.
// Reference: docs/cn/DesktopManagerSpec.md §3.3–§3.5 (message queue tid must match user32).
//
// **阶段 D-D2**：`get_message` / `post_message` 字节偏移与 `subsystem.zig` `handleApiCall`、`user32.csrFillOneMessageForLpc` 双端同改；`register_dwm_listener` 的 tid 回退策略见 `resolveDwmListenerTid`；GUI 桌面 ACL 路由见子系统 `seAccessActiveDesktopForWin32k` 调用点。

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

/// `CsrApiNumber.register_dwm_listener` 载荷 **v1**（小端）：前 4 字节魔数 `0x014D5744`（ASCII `DWM` + `0x01`）；`[4..8]` 为 `DWORD` 线程 id。
/// 否则（含仅 4 字节有效载荷的旧客户端）按 **旧版**：`[0..4]` 即为 tid（与既有 `subsystem` 行为一致）。
pub const register_dwm_listener_v1_magic_le: u32 = 0x014D5744;
pub const register_dwm_listener_v1_min_bytes: usize = 8;
pub const register_dwm_listener_tid_v1_off: usize = 4;

/// 从 LPC 载荷解析原始 tid（不含 `pid` 回退）；见 `resolveDwmListenerTid`。
pub fn readRegisterDwmListenerRawTid(data: []const u8) u32 {
    if (data.len >= register_dwm_listener_v1_min_bytes) {
        const m = std.mem.readInt(u32, data[0..4], .little);
        if (m == register_dwm_listener_v1_magic_le) {
            return std.mem.readInt(u32, data[register_dwm_listener_tid_v1_off..][0..4], .little);
        }
    }
    if (data.len >= 4) {
        return std.mem.readInt(u32, data[0..4], .little);
    }
    return 0;
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

test "register_dwm_listener v1 payload reads tid at offset 4" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], register_dwm_listener_v1_magic_le, .little);
    std.mem.writeInt(u32, buf[4..8], 0x1122_3344, .little);
    try std.testing.expectEqual(@as(u32, 0x1122_3344), readRegisterDwmListenerRawTid(&buf));
    try std.testing.expectEqual(@as(u32, 0x1122_3344), resolveDwmListenerTid(readRegisterDwmListenerRawTid(&buf), 99));
}

test "register_dwm_listener legacy tid 1 not confused with v1" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 1, .little);
    @memset(buf[4..8], 0);
    try std.testing.expectEqual(@as(u32, 1), readRegisterDwmListenerRawTid(&buf));
}

test "register_dwm_listener legacy 4-byte payload" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 55, .little);
    try std.testing.expectEqual(@as(u32, 55), readRegisterDwmListenerRawTid(&buf));
}

test "LPC payload offsets align with subsystem handleApiCall" {
    try std.testing.expect(post_message_wparam_off >= post_message_msg_off + 4);
    try std.testing.expect(get_message_tid_off == 20);
}

/// `open_desktop` / `switch_desktop`：`DSK1` 小端魔数（与 `LPC_NT61_HANDSHAKE.md` vNext 一致）。
pub const desktop_open_switch_magic_le: u32 = 0x44534B31;
/// `close_desktop`：`DSL1`。
pub const desktop_close_magic_le: u32 = 0x44534C31;
pub const desktop_payload_name_len_off: usize = 4;
pub const desktop_payload_name_off: usize = 5;
pub const desktop_name_max_len: u8 = 31;

pub fn parseDesktopNamedMessage(data: []const u8, expected_magic: u32) ?[]const u8 {
    if (data.len < desktop_payload_name_off) return null;
    const m = std.mem.readInt(u32, data[0..4], .little);
    if (m != expected_magic) return null;
    const n = data[desktop_payload_name_len_off];
    if (n == 0 or n > desktop_name_max_len) return null;
    if (desktop_payload_name_off + @as(usize, n) > data.len) return null;
    return data[desktop_payload_name_off .. desktop_payload_name_off + n];
}

pub fn readCloseDesktopHdesk(data: []const u8) ?u32 {
    if (data.len < 8) return null;
    const m = std.mem.readInt(u32, data[0..4], .little);
    if (m != desktop_close_magic_le) return null;
    return std.mem.readInt(u32, data[4..8], .little);
}

test "desktop DSK1 name payload round-trip" {
    var buf: [40]u8 = [_]u8{0} ** 40;
    std.mem.writeInt(u32, buf[0..4], desktop_open_switch_magic_le, .little);
    buf[4] = 3;
    @memcpy(buf[5..8], "abc");
    const nm = parseDesktopNamedMessage(&buf, desktop_open_switch_magic_le).?;
    try std.testing.expectEqualStrings("abc", nm);
}

test "desktop DSL1 close hdesk" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], desktop_close_magic_le, .little);
    std.mem.writeInt(u32, buf[4..8], 2, .little);
    try std.testing.expectEqual(@as(u32, 2), readCloseDesktopHdesk(&buf).?);
}

/// `user32.packMsgForLpc` / `csrFillOneMessageForLpc` 应答载荷；与 [LPC_NT61_HANDSHAKE.md](../../docs/cn/LPC_NT61_HANDSHAKE.md) 及 DesktopManagerSpec §3.4 一致。
pub const csr_reply_msg_packed_bytes: usize = 44;

test "csr get_message reply MSG layout is 44 bytes LE (hwnd,msg,pad,wparam,lparam,time,pt)" {
    try std.testing.expectEqual(@as(usize, 44), csr_reply_msg_packed_bytes);
    // u64+u32+u32+u64+i64+u32+i32+i32 — mirrors `user32.packMsgForLpc`.
    try std.testing.expectEqual(@as(usize, 44), 8 + 4 + 4 + 8 + 8 + 4 + 4 + 4);
}
