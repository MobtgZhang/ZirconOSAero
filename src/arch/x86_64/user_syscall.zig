// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero — NT user-mode syscall instruction shim.
// SDK layers call these wrappers; the machine instruction is kept in the
// architecture layer so user-facing ABI files remain ISA-neutral.

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
