//! 阶段 4 主机锚点：窗口站 LPC 操作码、WOW64 x86 LPC 相关服务号、NTFS ZOSH1 路径（与实现同源，防静默漂移）。
const std = @import("std");
const x86 = @import("ssdt_x86_win7_sp1");

/// 须与 `subsystem.zig` `CsrApiNumber` 一致。
pub const csr_open_desktop: u32 = 0x10028;
pub const csr_switch_desktop_lpc: u32 = 0x10029;
pub const csr_close_desktop_lpc: u32 = 0x1002A;

/// 须与 `hive.zig` `default_ntfs_dwm_overlay_vfs_path` 一致。
pub const ntfs_dwm_zosh_path = "D:\\System32\\Config\\ZirconUser.zosh";

test "phase4: windowstation CSR opcodes" {
    try std.testing.expectEqual(@as(u32, 0x10028), csr_open_desktop);
    try std.testing.expectEqual(@as(u32, 0x10029), csr_switch_desktop_lpc);
    try std.testing.expectEqual(@as(u32, 0x1002A), csr_close_desktop_lpc);
}

test "phase4: WOW64 x86 NtConnectPort and NtRequestWaitReplyPort stub success" {
    try std.testing.expect(x86.wow64SyscallStubReturnsSuccess(x86.NtConnectPort));
    try std.testing.expect(x86.wow64SyscallStubReturnsSuccess(x86.NtRequestWaitReplyPort));
    try std.testing.expectEqual(@as(u32, 0x3B), x86.NtConnectPort);
    try std.testing.expectEqual(@as(u32, 0x12B), x86.NtRequestWaitReplyPort);
}

test "phase4: NTFS DWM ZOSH1 path suffix" {
    try std.testing.expect(std.mem.endsWith(u8, ntfs_dwm_zosh_path, "ZirconUser.zosh"));
}
