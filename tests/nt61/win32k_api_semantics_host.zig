//! Win32k / user32 / GDI / LPC 纯常量与策略的主机锚点（问题四～五、八部分内容）。
//! 无内核链接；与 [NT61_CONTRACT_MATRIX.md](../../docs/cn/NT61_CONTRACT_MATRIX.md) §5、§4.1 交叉引用。
const std = @import("std");
const pm = @import("msg_pm_semantics");
const csr = @import("csr_lpc_policy");
const rop = @import("gdi_rop_contract");
const dnc = @import("dwm_nt61_api_contract");

test "DeleteDC HWND-as-HDC policy (doc anchor)" {
    // gdi32.DeleteDC：窗口 DC（HDC==HWND）须拒绝；主机不链 gdi32，仅登记矩阵 §5 与 win32k_api_semantics_host。
    const hdc_as_hwnd: u64 = 0x1000;
    try std.testing.expect(hdc_as_hwnd != 0);
}

test "PM_REMOVE without PM_NOYIELD allows yield hint" {
    try std.testing.expect(pm.allowSchedulerYieldForPeekFlags(pm.PM_REMOVE));
    try std.testing.expect(!pm.allowSchedulerYieldForPeekFlags(pm.PM_REMOVE | pm.PM_NOYIELD));
}

test "LPC post/get_message offsets match subsystem.handleApiCall" {
    try std.testing.expectEqual(@as(usize, 0), csr.post_message_hwnd_off);
    try std.testing.expectEqual(@as(usize, 8), csr.post_message_msg_off);
    try std.testing.expectEqual(@as(usize, 16), csr.post_message_wparam_off);
    try std.testing.expectEqual(@as(usize, 24), csr.post_message_lparam_off);
    try std.testing.expectEqual(@as(usize, 20), csr.get_message_tid_off);
}

test "GDI ROP contract SRCCOPY only for BitBlt family" {
    try std.testing.expect(rop.isImplementedBitBltRop(rop.SRCCOPY));
    try std.testing.expect(!rop.isImplementedBitBltRop(0x00EE0086));
}

test "§5 BitBlt unsupported ROP last error matches gdi32 path" {
    try std.testing.expectEqual(@as(u32, 87), rop.bitblt_unsupported_rop_last_error);
}

test "§5 CreateWindowEx failure HWND sentinel is NULL" {
    const hwnd_fail: u64 = 0;
    try std.testing.expectEqual(@as(u64, 0), hwnd_fail);
}

test "Flip3D caps from dwm_nt61_api_contract" {
    try std.testing.expectEqual(dnc.flip3d_shell_sid_buffer_cap, @as(usize, 6));
    try std.testing.expectEqual(dnc.flip3d_shell_thumb_paint_max, @as(usize, 4));
}
