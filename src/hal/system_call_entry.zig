//! Architecture-independent syscall entry adapters.

const ssdt = @import("../ssdt.zig");

export fn syscall_entry_x64(syscall_num: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) u64 {
    const args: [6]u64 = .{ arg1, arg2, arg3, arg4, arg5, arg6 };
    return ssdt.entryResult(ssdt.dispatchSyscall(@intCast(syscall_num), 6, &args));
}

export fn syscall_entry_arm64(syscall_num: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64, arg7: u64, arg8: u64) u64 {
    _ = arg7;
    _ = arg8;
    const args: [6]u64 = .{ arg1, arg2, arg3, arg4, arg5, arg6 };
    return ssdt.entryResult(ssdt.dispatchSyscall(@intCast(syscall_num), 6, &args));
}

export fn syscall_entry_loongarch64(syscall_num: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) u64 {
    const args: [6]u64 = .{ arg1, arg2, arg3, arg4, arg5, arg6 };
    return ssdt.entryResult(ssdt.dispatchSyscall(@intCast(syscall_num), 6, &args));
}

export fn syscall_entry_riscv64(syscall_num: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) u64 {
    const args: [6]u64 = .{ arg1, arg2, arg3, arg4, arg5, arg6 };
    return ssdt.entryResult(ssdt.dispatchSyscall(@intCast(syscall_num), 6, &args));
}
