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

//! MIPS64EL thread context initialization and switch wrappers.
//! The actual register save/restore is in context_switch.S.

/// Context frame layout saved by mips64_switch_context (23 doublewords = 184 bytes).
/// Must match the layout in context_switch.S exactly.
pub const MipsThreadContext = extern struct {
    s0: u64 = 0,
    s1: u64 = 0,
    s2: u64 = 0,
    s3: u64 = 0,
    s4: u64 = 0,
    s5: u64 = 0,
    s6: u64 = 0,
    s7: u64 = 0,
    gp: u64 = 0,
    fp: u64 = 0,
    ra: u64 = 0,
    status: u64 = 0,
    sp: u64 = 0,
    t0: u64 = 0,
    t1: u64 = 0,
    t2: u64 = 0,
    t3: u64 = 0,
    t4: u64 = 0,
    t5: u64 = 0,
    t6: u64 = 0,
    t7: u64 = 0,
    t8: u64 = 0,
    t9: u64 = 0,
};

const CTX_SIZE: usize = 184;

comptime {
    if (@sizeOf(MipsThreadContext) != CTX_SIZE) @compileError("MipsThreadContext size mismatch with context_switch.S");
}

pub extern fn mips64_switch_context(from: *MipsThreadContext, to: *MipsThreadContext) callconv(.c) void;

/// Prepare a new thread's context so that when mips64_switch_context restores
/// from it, execution begins at entry_fn.
/// Called from scheduler.createThread with (ctx_ptr, entry, stack_end).
pub fn initNewThread(ctx: *MipsThreadContext, entry: u64, stack_top: usize) void {
    var sp = stack_top;
    // Reserve space for context frame (will be "popped" by mips64_switch_context)
    sp -= 8;
    @as(*align(8) u64, @ptrFromInt(sp)).* = entry;

    ctx.* = .{
        .s0 = 0,
        .s1 = 0,
        .s2 = 0,
        .s3 = 0,
        .s4 = 0,
        .s5 = 0,
        .s6 = 0,
        .s7 = 0,
        .gp = 0,
        .fp = 0,
        .ra = entry,
        // Status: IE=1, KX=1, SX=1, UX=1
        .status = (1 << 0) | (1 << 5) | (1 << 6) | (1 << 7),
        .sp = sp,
        .t0 = 0,
        .t1 = 0,
        .t2 = 0,
        .t3 = 0,
        .t4 = 0,
        .t5 = 0,
        .t6 = 0,
        .t7 = 0,
        .t8 = 0,
        .t9 = 0,
    };
}
