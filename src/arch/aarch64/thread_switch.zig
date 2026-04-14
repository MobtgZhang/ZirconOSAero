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

//! AArch64 thread context and cooperative switch (see context_switch.S).

pub const A64ThreadContext = extern struct {
    x19: u64,
    x20: u64,
    x21: u64,
    x22: u64,
    x23: u64,
    x24: u64,
    x25: u64,
    x26: u64,
    x27: u64,
    x28: u64,
    x29: u64, // FP
    x30: u64, // LR
    sp: u64,
};

pub extern fn aarch64_switch_context(from: *A64ThreadContext, to: *A64ThreadContext) callconv(.c) void;
pub extern fn aarch64_thread_trampoline() void;

pub fn trampolineAddr() usize {
    return @intFromPtr(&aarch64_thread_trampoline);
}

/// Prepare a new kernel thread: entry address pushed on stack, lr -> trampoline.
pub fn initNewThread(ctx: *A64ThreadContext, entry: u64, stack_top: usize) void {
    var sp = stack_top;
    sp -= 8;
    @as(*align(8) u64, @ptrFromInt(sp)).* = entry;
    ctx.* = .{
        .x19 = 0,
        .x20 = 0,
        .x21 = 0,
        .x22 = 0,
        .x23 = 0,
        .x24 = 0,
        .x25 = 0,
        .x26 = 0,
        .x27 = 0,
        .x28 = 0,
        .x29 = 0,
        .x30 = trampolineAddr(),
        .sp = sp,
    };
}
