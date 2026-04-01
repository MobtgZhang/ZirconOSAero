// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/arch/x86_64/syscall_msr.zig
// Purpose: Enable AMD64 `syscall`/`sysret` via IA32_EFER.SCE and STAR/LSTAR/FMASK (与 IDT 向量 128 并存).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: Intel SDM Vol.4 MSR IA32_EFER / IA32_STAR / IA32_LSTAR / IA32_FMASK

const gdt = @import("../../hal/x86_64/gdt.zig");
const klog = @import("../../rtl/klog.zig");

extern fn syscall_lstar_entry() void;

const IA32_EFER: u32 = 0xC000_0080;
const IA32_STAR: u32 = 0xC000_0081;
const IA32_LSTAR: u32 = 0xC000_0082;
const IA32_FMASK: u32 = 0xC000_0084;

fn rdmsr(msr: u32) u64 {
    var eax: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("rdmsr"
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [ecx] "{ecx}" (msr),
        : .{ .memory = true });
    return (@as(u64, edx) << 32) | eax;
}

fn wrmsr(msr: u32, value: u64) void {
    const eax: u32 = @truncate(value);
    const edx: u32 = @truncate(value >> 32);
    asm volatile ("wrmsr"
        :
        : [ecx] "{ecx}" (msr),
          [eax] "{eax}" (eax),
          [edx] "{edx}" (edx),
        : .{ .memory = true });
}

fn cpuidExt80000001_edx() u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (@as(u32, 0x8000_0001)),
          [sub] "{ecx}" (@as(u32, 0)),
        : .{ .memory = true });
    // 绑定全部输出寄存器，避免 Zig 0.15「无意义丢弃」诊断；位特征仅看 EDX。
    _ = eax ^ ebx ^ ecx;
    return edx;
}

/// 若 CPU 支持且 `zircon_x86_64_kernel_rsp0` 已初始化，则启用 `syscall` 入口；`int 0x80` 仍可用。
pub fn initSyscallInstructionPath() void {
    if (gdt.zircon_x86_64_kernel_rsp0 == 0) return;
    const feat = cpuidExt80000001_edx();
    if ((feat & (1 << 11)) == 0) {
        if (klog.DEBUG_MODE) {
            klog.debug("syscall: CPU lacks SYSCALL/SYSRET (cpuid 80000001h.edx.11)", .{});
        }
        return;
    }

    var efer = rdmsr(IA32_EFER);
    efer |= 1; // SCE
    wrmsr(IA32_EFER, efer);

    // STAR[47:32]=syscall 时内核 CS；STAR[63:48]=SYSRET 基址，须满足 SS=基+8、CS=基+16（见 gdt.IA32_STAR_SYSRET_BASE）。
    const star: u64 = (@as(u64, gdt.IA32_STAR_SYSRET_BASE) << 48) | (@as(u64, gdt.KERNEL_CS) << 32);
    wrmsr(IA32_STAR, star);

    const lstar = @intFromPtr(&syscall_lstar_entry);
    wrmsr(IA32_LSTAR, lstar);

    wrmsr(IA32_FMASK, 1 << 9);

    if (klog.DEBUG_MODE) {
        klog.debug("syscall: IA32_LSTAR enabled (int 0x80 vector 128 still active)", .{});
    }
}
