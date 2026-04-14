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
// Module: src/hal/x86_64/percpu.zig
// Purpose: BSP/AP per-CPU 块：`syscall` 入口 `SWAPGS` 后 `%gs:0` = 内核 RSP0；扩展处理器号与当前线程索引（与 `ke/kpcr.zig` 一致）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: Intel SDM Vol.2 SWAPGS; Vol.4 IA32_KERNEL_GS_BASE MSR (0xC0000102)

/// Layout must match `syscall_lstar.s`: first qword is kernel RSP0 for SYSCALL entry。
pub const PerCpu = extern struct {
    kernel_rsp0: u64 align(8) = 0,
    processor_number: u32 align(8) = 0,
    current_thread_index: i32 = -1,
    _pad: u32 = 0,
};

/// BSP 块；AP 使用 `ap_percpu_blocks` 中对应项。
/// **SMP / syscall**：`ap_entry.apTrampolineIntermediate` 在绑定 TSS 后为每 AP 填写 `kernel_rsp0` 并 `publishApPerCpuBlock`，
/// 与 BSP 上 `syncKernelRsp0` 对称，保证 `syscall` 入口 `SWAPGS` 后 `%gs:0` 指向本核 RSP0。
pub export var zircon_x86_64_percpu: PerCpu = .{};

/// AP（`cpu_index` 1..7）的 per-CPU 块；由 `ap_entry` 在跳板第二阶段绑定 `IA32_KERNEL_GS_BASE`。
pub var ap_percpu_blocks: [7]PerCpu align(16) = @splat(.{});

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
    zircon_x86_64_percpu.processor_number = 0;
    zircon_x86_64_percpu.current_thread_index = -1;
    wrmsr(IA32_KERNEL_GS_BASE, @intFromPtr(&zircon_x86_64_percpu));
}

/// AP：绑定独立 `PerCpu` 与 `IA32_KERNEL_GS_BASE`（须在已设置 RSP 与 TSS.RSP0 之后调用）。
pub fn publishApPerCpuBlock(block: *PerCpu) void {
    wrmsr(IA32_KERNEL_GS_BASE, @intFromPtr(block));
}
