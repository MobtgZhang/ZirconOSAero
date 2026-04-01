// SPDX-License-Identifier: MIT OR Apache-2.0
// Parity: `src/sdk/ntdll_syscall_win64.zig` `Ssdt` vs `src/arch/x86_64/ssdt_nt61.zig` (build.zig wires modules).

const std = @import("std");
const ssdt = @import("ssdt");
const stub = @import("stub");

test "user syscall stub Ssdt matches ssdt_nt61" {
    try std.testing.expectEqual(ssdt.NtClose, stub.Ssdt.NtClose);
    try std.testing.expectEqual(ssdt.NtYieldExecution, stub.Ssdt.NtYieldExecution);
    try std.testing.expectEqual(ssdt.NtAllocateVirtualMemory, stub.Ssdt.NtAllocateVirtualMemory);
    try std.testing.expectEqual(ssdt.NtFreeVirtualMemory, stub.Ssdt.NtFreeVirtualMemory);
    try std.testing.expectEqual(ssdt.NtQuerySystemInformation, stub.Ssdt.NtQuerySystemInformation);
}
