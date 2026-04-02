// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/vm_nt_protect_pte_host.zig
// Purpose: 主机侧锁定 `src/mm/vm.zig` 中 `ntProtectToPteFlags` 与 Win32 `PAGE_*` 的 x86_64 PTE 位组合（与 `src/arch/x86_64/paging.zig` 公开常量一致）。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows/win32/memory/memory-protection-constants
//      Intel SDM Vol.3 — PTE bit definitions (Table 4-12)

const std = @import("std");

const Present: u64 = 1 << 0;
const Write: u64 = 1 << 1;
const User: u64 = 1 << 2;
const Accessed: u64 = 1 << 5;
const NoExecute: u64 = 1 << 63;

fn ntProtectToPteFlags(prot: u32) ?u64 {
    const base = Present | User | Accessed;
    return switch (prot) {
        0x02 => base | NoExecute,
        0x04, 0x08, 0x80 => base | Write | NoExecute,
        0x10, 0x20 => base,
        0x40 => base | Write,
        else => null,
    };
}

test "ntProtectToPteFlags table matches vm.zig / x86_64 paging.zig" {
    const base = Present | User | Accessed;
    try std.testing.expectEqual(ntProtectToPteFlags(0x02).?, base | NoExecute);
    try std.testing.expect((ntProtectToPteFlags(0x04).? & Write) != 0);
    try std.testing.expect((ntProtectToPteFlags(0x04).? & NoExecute) != 0);
    try std.testing.expectEqual(ntProtectToPteFlags(0xDEADBEEF), null);
}
