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

//! RISC-V 64 thread context and cooperative switch (see context_switch.S).

pub const RvThreadContext = extern struct {
    ra: u64,
    sp: u64,
    s0: u64,
    s1: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
};

pub extern fn riscv_switch_context(from: *RvThreadContext, to: *RvThreadContext) callconv(.c) void;

pub fn trampolineAddr() usize {
    return asm volatile (
        "lla %[o], riscv_thread_trampoline"
        : [o] "=r" (-> usize),
    );
}

/// Prepare a new kernel thread: entry address pushed on stack, ra → trampoline.
pub fn initNewThread(ctx: *RvThreadContext, entry: u64, stack_top: usize) void {
    var sp = stack_top;
    sp -= 8;
    @as(*align(8) u64, @ptrFromInt(sp)).* = entry;
    ctx.* = .{
        .ra = trampolineAddr(),
        .sp = sp,
        .s0 = 0,
        .s1 = 0,
        .s2 = 0,
        .s3 = 0,
        .s4 = 0,
        .s5 = 0,
        .s6 = 0,
        .s7 = 0,
        .s8 = 0,
        .s9 = 0,
        .s10 = 0,
        .s11 = 0,
    };
}
