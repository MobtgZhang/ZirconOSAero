// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/sdk/ntdll_syscall_win64.zig
// Purpose: **用户态** NT x64 `syscall` 薄封装（与内核 `syscall.zig` 中 SSDT 号一致）。
// 供未来用户进程或测试 PE 与 `src/libs/ntdll.zig`（内核内联桩）分离。
//
// This is an independent clean-room implementation.
// Ref: Intel SDM SYSCALL/SYSRET；索引与 `src/arch/x86_64/ssdt_nt61.zig` **须一致**（`zig build test` → **ssdt_stub_parity**）。

//! **注意**：在主机 Linux 上执行 `syscall` 会非法；仅在与本内核配对的用户态镜像中链接。
//! 第 1 参须放在 **`R10`**（与 Linux 习惯不同）。

/// 与 `ssdt_nt61.zig` 同步的 SSDT 索引子集（本文件可单独 `zig build-obj` 而无需整棵模块树）。
pub const Ssdt = struct {
    pub const NtClose: u32 = 0x0C;
    pub const NtOpenKey: u32 = 0x0F;
    pub const NtQueryValueKey: u32 = 0x14;
    pub const NtCreateKey: u32 = 0x1A;
    pub const NtSetValueKey: u32 = 0x5D;
    pub const NtYieldExecution: u32 = 0x43;
    pub const NtAllocateVirtualMemory: u32 = 0x18;
    pub const NtFreeVirtualMemory: u32 = 0x1B;
    pub const NtDelayExecution: u32 = 0x31;
    pub const NtCreateThread: u32 = 0x4B;
    pub const NtProtectVirtualMemory: u32 = 0x4D;
    pub const NtQuerySystemInformation: u32 = 0x25;
    pub const NtDuplicateObject: u32 = 0x44;
};

/// 原始 NT x64 syscall；`num` 为 SSDT 索引；返回值按 NTSTATUS 符号扩展。
pub fn ntSyscall0(num: u32) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [n] "{rax}" (@as(u64, num)),
          [r10] "{r10}" (@as(u64, 0)),
          [rdx] "{rdx}" (@as(u64, 0)),
          [r8] "{r8}" (@as(u64, 0)),
          [r9] "{r9}" (@as(u64, 0)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn ntSyscall1(num: u32, a1: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [n] "{rax}" (@as(u64, num)),
          [r10] "{r10}" (a1),
          [rdx] "{rdx}" (@as(u64, 0)),
          [r8] "{r8}" (@as(u64, 0)),
          [r9] "{r9}" (@as(u64, 0)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn ntSyscall4(num: u32, a1: u64, a2: u64, a3: u64, a4: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [n] "{rax}" (@as(u64, num)),
          [r10] "{r10}" (a1),
          [rdx] "{rdx}" (a2),
          [r8] "{r8}" (a3),
          [r9] "{r9}" (a4),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn ntCloseUser(handle: u64) i64 {
    return ntSyscall1(Ssdt.NtClose, handle);
}

pub fn ntYieldExecutionUser() i64 {
    return ntSyscall0(Ssdt.NtYieldExecution);
}

comptime {
    _ = Ssdt.NtClose;
    _ = Ssdt.NtOpenKey;
    _ = Ssdt.NtQueryValueKey;
    _ = Ssdt.NtCreateKey;
    _ = Ssdt.NtSetValueKey;
    _ = Ssdt.NtYieldExecution;
    _ = Ssdt.NtAllocateVirtualMemory;
    _ = Ssdt.NtFreeVirtualMemory;
    _ = Ssdt.NtDelayExecution;
    _ = Ssdt.NtCreateThread;
    _ = Ssdt.NtProtectVirtualMemory;
    _ = Ssdt.NtQuerySystemInformation;
    _ = Ssdt.NtDuplicateObject;
}
