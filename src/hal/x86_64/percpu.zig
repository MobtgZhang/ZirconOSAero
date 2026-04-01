// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/percpu.zig
// Purpose: BSP per-CPU block for `syscall` entry (`SWAPGS` + `%gs:0` = kernel RSP0).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: Intel SDM Vol.2 SWAPGS; Vol.4 IA32_KERNEL_GS_BASE MSR (0xC0000102)

/// Layout must match `syscall_lstar.s`: first qword is kernel RSP0 for SYSCALL entry.
pub const PerCpu = extern struct {
    kernel_rsp0: u64 align(8) = 0,
};

/// BSP 块；多核时可为数组并由 AP 在启动时各自 `wrmsr` `IA32_KERNEL_GS_BASE`。
pub export var zircon_x86_64_percpu: PerCpu = .{};

const IA32_KERNEL_GS_BASE: u32 = 0xC0000102;

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

/// 与 `gdt.setKernelStack` / `zircon_x86_64_kernel_rsp0` 同步；并写入 `IA32_KERNEL_GS_BASE` 供 `SWAPGS` 后 `%gs:0` 寻址。
pub fn syncKernelRsp0(rsp0: u64) void {
    zircon_x86_64_percpu.kernel_rsp0 = rsp0;
    wrmsr(IA32_KERNEL_GS_BASE, @intFromPtr(&zircon_x86_64_percpu));
}
