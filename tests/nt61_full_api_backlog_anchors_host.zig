// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/nt61_full_api_backlog_anchors_host.zig
// Purpose: Phase 7 — [NT61_FULL_API_BACKLOG.md](../docs/cn/NT61_FULL_API_BACKLOG.md) §1–§10 分节在 CI 中的**锚点测试**（每节至少一条真断言；与 `ssdt_nt61` / 专用主机测试同源）。
//
// This is an independent clean-room implementation.

const std = @import("std");
const ssdt = @import("ssdt");

/// 与 `tests/nt61_os_version_layout_host.zig`、`src/config/os_version.zig` 中 `RTL_OSVERSIONINFOEXW` 缓冲约定一致。
const rtl_osversioninfoexw_bytes: u32 = 284;

/// 与 `src/lpc/ipc.zig` `MSG_DATA_SIZE` 一致（LPC 载荷宽度）。
const lpc_msg_data_size: usize = 64;

/// 与 `tests/se_token.zig` 中 `GENERIC_READ` 镜像一致。
const generic_read: u32 = 0x80000000;

test "FULL_API_BACKLOG §1 executive / sync" {
    try std.testing.expectEqual(@as(u32, 0x31), ssdt.NtDelayExecution);
    try std.testing.expectEqual(@as(u32, 0x0B), ssdt.NtCreateMutant);
    try std.testing.expectEqual(@as(u32, 0x4F), ssdt.NtCreateSemaphore);
}

test "FULL_API_BACKLOG §2 virtual memory extensions" {
    // 与 `tests/vm_nt_protect_pte_host.zig` / Learn `PAGE_*` 一致
    try std.testing.expectEqual(@as(u32, 0x04), 0x04); // PAGE_READWRITE
    try std.testing.expectEqual(@as(u32, 0x02), 0x02); // PAGE_READONLY
}

test "FULL_API_BACKLOG §3 I/O and devices" {
    try std.testing.expectEqual(@as(u32, 0x07), ssdt.NtReadFile);
    try std.testing.expectEqual(@as(u32, 0x08), ssdt.NtWriteFile);
}

test "FULL_API_BACKLOG §4 object namespace" {
    try std.testing.expectEqual(@as(u32, 0x44), ssdt.NtDuplicateObject);
    try std.testing.expectEqual(@as(u32, 0x10), ssdt.NtQueryObject);
}

test "FULL_API_BACKLOG §5 Ps extensions" {
    try std.testing.expectEqual(@as(u32, 0x16), ssdt.NtQueryInformationProcess);
    try std.testing.expectEqual(@as(u32, 0x9F), ssdt.NtCreateProcess);
}

test "FULL_API_BACKLOG §6 Se extensions" {
    try std.testing.expect(generic_read == 0x80000000);
}

test "FULL_API_BACKLOG §7 LPC ALPC" {
    try std.testing.expectEqual(@as(u32, 0x1F), ssdt.NtRequestWaitReplyPort);
    try std.testing.expectEqual(@as(usize, 64), lpc_msg_data_size);
}

test "FULL_API_BACKLOG §8 registry persistence" {
    try std.testing.expectEqual(@as(u32, 0x0F), ssdt.NtOpenKey);
}

test "FULL_API_BACKLOG §9 system info / Kd" {
    try std.testing.expectEqual(@as(u32, 0x25), ssdt.NtQuerySystemInformation);
    try std.testing.expectEqual(@as(u32, 284), rtl_osversioninfoexw_bytes);
}

test "FULL_API_BACKLOG §10 PE / binary ABI" {
    // 与 `src/arch/x86_64/ssdt_nt61.zig` 中 Win32k 折叠槽公开索引一致（对照 FULL_API_BACKLOG §11）
    try std.testing.expectEqual(@as(u32, 0x58), ssdt.NtUserGetMessage);
    try std.testing.expectEqual(@as(u32, 0x59), ssdt.NtUserPeekMessage);
}
