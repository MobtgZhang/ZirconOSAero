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

//! 安装 CSR.EENTRY 向量区、ECFG 向量间距；与 `exc_vec.S` 中 `loongarch_exc_vectors` 配套。

const klog = @import("../../rtl/klog.zig");
const interrupt_la = @import("../../ke/interrupt_loongarch.zig");
const syscall_la = @import("syscall_la.zig");

/// `exc_vec.S` 中全局符号；勿用 `@intFromPtr(&extern …)` —— 与 `_kernel_end` 相同，部分 Zig 版本在 LoongArch 上会得到 0，CSR.EENTRY=0 会导致定时器/中断入口跳转到空地址，桌面刚起来即崩溃或 QEMU 退出。
fn haltForever() noreturn {
    while (true) {
        asm volatile ("idle 0");
    }
}

fn excVectorsBase() usize {
    return asm volatile ("la.local %[o], loongarch_exc_vectors"
        : [o] "=r" (-> usize),
    );
}

fn csrRdEcfg() u64 {
    return asm volatile ("csrrd %[o], 0x4"
        : [o] "=r" (-> u64),
    );
}

fn csrWrEcfg(val: u64) void {
    asm volatile ("csrwr %[v], 0x4"
        :
        : [v] "r" (val),
    );
}

fn csrWrEentry(val: u64) void {
    asm volatile ("csrwr %[v], 0xc"
        :
        : [v] "r" (val),
    );
}

export fn loongarch_dispatch_trap(frame_sp: usize) callconv(.c) void {
    // CSR 0x5 = ESTAT（Exception STATus），包含 ExcCode@[21:16] 和 IS@[14:0]
    // ESTAT.EXC=11 对应 syscall（ECALL/break）
    const estat = asm volatile ("csrrd %[o], 0x5"
        : [o] "=r" (-> u64),
    );
    const exc = interrupt_la.resolvedExcCode(estat);
    if (exc == 11) {
        syscall_la.handleFromTrapFrame(frame_sp);
        return;
    }
    if (exc >= 1 and exc <= 4) {
        interrupt_la.handleTlbPageFault(exc);
        return;
    }
    if (exc < 64) {
        const ew = @as(u32, @truncate(estat));
        klog.err("LoongArch: exception EC=%u ESTAT.lo=0x%x (see ESTAT/BADV)", .{ exc, ew });
        haltForever();
    }
    interrupt_la.dispatchHardwareInterrupts(exc, @as(u32, @truncate(estat)));
}

/// CSR.ECFG VS 域：向量间距 = 4 << VS；512B → VS=7
const ECFG_VS_SHIFT: u6 = 16;
const ECFG_VS_MASK: u64 = 0x7 << ECFG_VS_SHIFT;
const ECFG_IM_MASK: u64 = 0x3FFF;

pub fn init() void {
    const arch = @import("../../arch.zig");
    arch.disableInterrupts();

    const base_raw = excVectorsBase();
    const base_pg = base_raw & ~@as(usize, 0xFFF);
    csrWrEentry(@as(u64, @intCast(base_pg)));

    var ecfg = csrRdEcfg();
    ecfg = (ecfg & ~ECFG_VS_MASK) | (@as(u64, 7) << ECFG_VS_SHIFT);
    ecfg &= ~ECFG_IM_MASK;
    csrWrEcfg(ecfg);

    asm volatile ("ibar 0" ::: .{ .memory = true });
    klog.info("LoongArch traps: EENTRY=0x%x (vec=0x%x) VS=512B", .{ base_pg, base_raw });
}

pub fn ecfgEnableInterruptMask(im_bits: u64) void {
    var ecfg = csrRdEcfg();
    ecfg |= im_bits & ECFG_IM_MASK;
    csrWrEcfg(ecfg);
}
