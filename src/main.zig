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

const builtin = @import("builtin");
const arch = @import("arch.zig");
const klog = @import("rtl/klog.zig");
const std = @import("std");

pub const std_options: std.Options = .{
    .page_size_max = 4096,
};

// Zig 0.15.2 freestanding target workaround
//
// PROBLEM: Zig 0.15 introduced std.Options.page_size_max requirement for freestanding targets.
// When this is provided, std.heap.page_allocator uses PageAllocator internally, which
// depends on std.posix. However, std.posix.system struct has no members (E, MREMAP,
// MAP, etc.) for freestanding/other OS targets, causing compilation errors.
//
// This is a Zig stdlib design issue: PageAllocator unconditionally references std.posix
// even when those symbols don't exist for the target OS.
//
// Related Zig issues:
// - Zig stdlib std/heap.zig:56 requires page_size_max for freestanding
// - Zig stdlib std/posix.zig:69-85 references missing system.* members
//
// WORKAROUND: Override std.heap.page_allocator with an empty stub since ZirconOS
// uses its own heap implementation (src/mm/heap.zig) and never calls std.heap.page_allocator.
pub const os = struct {
    pub const heap = struct {
        pub const page_allocator: std.mem.Allocator = .{
            .ptr = undefined,
            .vtable = &empty_allocator_vtable,
        };
    };
};

const empty_allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = emptyAlloc,
    .resize = emptyResize,
    .free = emptyFree,
    .remap = emptyRemap,
};

fn emptyAlloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    return null;
}

fn emptyResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn emptyFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
    return;
}

fn emptyRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

pub const panic = std.debug.FullPanic(panicImpl);

fn writeHexU32ToConsole(n: u32) void {
    var buf: [8]u8 = undefined;
    var x = n;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        const d: u4 = @truncate(x & 15);
        const du = @as(u8, d);
        buf[i] = if (d < 10) '0' + du else 'a' + (du - 10);
        x >>= 4;
    }
    arch.consoleWrite(buf[0..]);
}

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    arch.consoleWrite("KERNEL PANIC: ");
    arch.consoleWrite(msg);
    const phase = @import("rtl/panic_context.zig").getPhase();
    if (phase != 0) {
        arch.consoleWrite(" [phase=0x");
        writeHexU32ToConsole(phase);
        arch.consoleWrite("]");
    }
    // 与配置里 `build_type=debug` 无关；避免 Release 内核 panic 时不带 phase。
    arch.consoleWrite(" [zig_opt=");
    arch.consoleWrite(@tagName(builtin.mode));
    arch.consoleWrite("]");
    arch.consoleWrite("\n");
    arch.halt();
}

extern const stack_top: u8;
extern const _kernel_end: u8;

comptime {
    _ = @import("kernel/force_link.zig");
}

/// UEFI/汇编以 64 位寄存器传参；首参截断为 u32 供 Multiboot2 magic 比对（与 LoongArch handoff 习惯一致）。
pub export fn kernel_main(magic_arg: usize, info_addr: usize) callconv(.c) noreturn {
    const magic = @as(u32, @truncate(magic_arg));
    switch (builtin.target.cpu.arch) {
        .x86_64 => @import("kernel/boot_x86_64.zig").start(magic, info_addr),
        else => @import("kernel/boot_generic.zig").start(magic, info_addr),
    }
}
