// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/arch/x86_64/syscall_msr.zig
// Purpose: Enable AMD64 `syscall`/`sysret` via IA32_EFER.SCE and STAR/LSTAR/FMASK（x86_64 唯一用户态 syscall 入口）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: Intel SDM Vol.4 MSR IA32_EFER / IA32_STAR / IA32_LSTAR / IA32_FMASK

const gdt = @import("../../hal/x86_64/gdt.zig");
const klog = @import("../../rtl/klog.zig");
const bugcheck = @import("../../ke/bugcheck.zig");

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

/// 若 CPU 支持且 `zircon_x86_64_kernel_rsp0` 已初始化，则启用 `syscall` 入口。
/// **启动序**：须于 `main` 在 `arch.initGdt`（设 TSS.RSP0 / `zircon_x86_64_kernel_rsp0`）**之后**调用（见 `main.zig` Phase 2 注释）。
/// 无 SYSCALL/SYSRET 时 **停机**：已移除 IDT `int 0x80` 路径，用户态无法进入内核 syscall 分发器。
/// Ref: Intel SDM — SYSCALL/SYSRET feature bit (CPUID 80000001H:EDX bit 11).
pub fn initSyscallInstructionPath() void {
    if (gdt.zircon_x86_64_kernel_rsp0 == 0) {
        klog.warn("syscall: skipped (kernel RSP0 not set yet)", .{});
        return;
    }
    const feat = cpuidExt80000001_edx();
    if ((feat & (1 << 11)) == 0) {
        klog.crit("syscall: CPU lacks SYSCALL/SYSRET (cpuid 80000001h.edx.11); no user syscall path — halting", .{});
        bugcheck.keBugCheckEx(.unexpected_kernel_mode_trap, 0x8000_0001, 11, feat, 0);
    }

    var efer = rdmsr(IA32_EFER);
    efer |= 1; // SCE
    wrmsr(IA32_EFER, efer);

    // STAR[47:32]=syscall 时内核 CS；STAR[63:48]=SYSRET 基址，须满足 SS=基+8、CS=基+16（见 gdt.IA32_STAR_SYSRET_BASE）。
    const star: u64 = (@as(u64, gdt.IA32_STAR_SYSRET_BASE) << 48) | (@as(u64, gdt.KERNEL_CS) << 32);
    wrmsr(IA32_STAR, star);

    const lstar = @intFromPtr(&syscall_lstar_entry);
    wrmsr(IA32_LSTAR, lstar);

    // 清 IF（位 9）与 DF（位 10）：避免用户态方向标志/中断屏蔽泄漏进内核路径（Intel SDM Vol.2 SYSCALL）。
    wrmsr(IA32_FMASK, (@as(u64, 1) << 9) | (@as(u64, 1) << 10));

    const percpu = @import("../../hal/x86_64/percpu.zig");
    percpu.syncKernelRsp0(gdt.zircon_x86_64_kernel_rsp0);

    klog.info("syscall/sysret: enabled (IA32_LSTAR=syscall_lstar_entry)", .{});
    if (klog.DEBUG_MODE) {
        klog.debug("syscall: per-CPU KERNEL_GS_BASE (SWAPGS) synced to RSP0", .{});
    }
}
