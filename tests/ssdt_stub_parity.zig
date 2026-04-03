// SPDX-License-Identifier: MIT OR Apache-2.0
// Parity: `src/sdk/ntdll_syscall_win64.zig` `Ssdt` vs `src/arch/x86_64/ssdt_nt61.zig` (build.zig wires modules).

const std = @import("std");
const ssdt = @import("ssdt");
const stub = @import("stub");

test "ZOA NtCreateUserProcess args struct 32 bytes" {
    const Z = extern struct {
        image_path_unicode: u64,
        process_handle_out: u64,
        thread_handle_out: u64,
        creation_flags: u32,
        reserved: u32,
    };
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Z));
}

test "user syscall stub Ssdt matches ssdt_nt61" {
    try std.testing.expectEqual(ssdt.NtClose, stub.Ssdt.NtClose);
    try std.testing.expectEqual(ssdt.NtWaitForSingleObject, stub.Ssdt.NtWaitForSingleObject);
    try std.testing.expectEqual(ssdt.NtOpenKey, stub.Ssdt.NtOpenKey);
    try std.testing.expectEqual(ssdt.NtQueryValueKey, stub.Ssdt.NtQueryValueKey);
    try std.testing.expectEqual(ssdt.NtCreateKey, stub.Ssdt.NtCreateKey);
    try std.testing.expectEqual(ssdt.NtSetValueKey, stub.Ssdt.NtSetValueKey);
    try std.testing.expectEqual(ssdt.NtEnumerateKey, stub.Ssdt.NtEnumerateKey);
    try std.testing.expectEqual(ssdt.NtEnumerateValueKey, stub.Ssdt.NtEnumerateValueKey);
    try std.testing.expectEqual(ssdt.NtYieldExecution, stub.Ssdt.NtYieldExecution);
    try std.testing.expectEqual(ssdt.NtAllocateVirtualMemory, stub.Ssdt.NtAllocateVirtualMemory);
    try std.testing.expectEqual(ssdt.NtFreeVirtualMemory, stub.Ssdt.NtFreeVirtualMemory);
    try std.testing.expectEqual(ssdt.NtDelayExecution, stub.Ssdt.NtDelayExecution);
    try std.testing.expectEqual(ssdt.NtCreateThread, stub.Ssdt.NtCreateThread);
    try std.testing.expectEqual(ssdt.NtProtectVirtualMemory, stub.Ssdt.NtProtectVirtualMemory);
    try std.testing.expectEqual(ssdt.NtQuerySystemInformation, stub.Ssdt.NtQuerySystemInformation);
    try std.testing.expectEqual(ssdt.NtDuplicateObject, stub.Ssdt.NtDuplicateObject);
    try std.testing.expectEqual(ssdt.NtCreateProcess, stub.Ssdt.NtCreateProcess);
    try std.testing.expectEqual(ssdt.NtCreateUserProcess, stub.Ssdt.NtCreateUserProcess);
    try std.testing.expectEqual(ssdt.NtWaitForMultipleObjects, stub.Ssdt.NtWaitForMultipleObjects);
    try std.testing.expectEqual(ssdt.NtSetInformationObject, stub.Ssdt.NtSetInformationObject);
    try std.testing.expectEqual(ssdt.NtSignalAndWaitForSingleObject, stub.Ssdt.NtSignalAndWaitForSingleObject);
    try std.testing.expectEqual(ssdt.NtQueryInformationProcess, stub.Ssdt.NtQueryInformationProcess);
}
