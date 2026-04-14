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

//! LoongArch64：`syscall` 指令 → ExcCode=11；从 `exc_vec.S` 最小帧读服务号并写回返回值。
//! 完整 NT SSDT 接线前：仅作可观测桩；返用户前须与 `vm.AddressSpace.activate` 协同（见 MemoryManagement 规格）。

const klog = @import("../../rtl/klog.zig");
const build_options = @import("build_options");

/// `exc_vec.S` 帧布局须与此一致（字节偏移）。
const OFF_A0: usize = 8;
const OFF_A7: usize = 64;

fn readU64(frame_sp: usize, off: usize) u64 {
    return @as(*const volatile u64, @ptrFromInt(frame_sp + off)).*;
}

fn writeU64(frame_sp: usize, off: usize, v: u64) void {
    @as(*volatile u64, @ptrFromInt(frame_sp + off)).* = v;
}

fn eraRead() u64 {
    return asm volatile ("csrrd %[o], 0x6"
        : [o] "=r" (-> u64),
    );
}

fn eraWrite(v: u64) void {
    asm volatile ("csrwr %[v], 0x6"
        :
        : [v] "r" (v),
    );
}

/// 由 `traps.loongarch_dispatch_trap` 在解析 ExcCode==11 后调用。
pub fn handleFromTrapFrame(frame_sp: usize) void {
    const svc = readU64(frame_sp, OFF_A7);
    if (build_options.debug) {
        klog.debug("LoongArch syscall: idx=0x%x a0=0x%x", .{
            @as(u32, @truncate(svc)), @as(u32, @truncate(readU64(frame_sp, OFF_A0))),
        });
    }

    const syscall_dispatch = @import("syscall_dispatch.zig");
    const result = syscall_dispatch.dispatch(frame_sp);
    writeU64(frame_sp, OFF_A0, result);

    const era = eraRead();
    eraWrite(era + 4);

    @import("../../ke/apc.zig").deliverKernelApcsForCurrentThread();

    const process = @import("../../ps/process.zig");
    if (process.getCurrentProcess()) |proc| {
        if (proc.address_space) |asp| asp.activate();
    }
}
