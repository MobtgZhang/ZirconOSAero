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

//! 中断分发入口：x86_64 走 IDT；其它架构由各自 trap/空实现承担。

const builtin = @import("builtin");

pub const InterruptFrame = switch (builtin.target.cpu.arch) {
    .x86_64 => @import("interrupt_x86.zig").InterruptFrame,
    else => @import("interrupt_stub.zig").InterruptFrame,
};

pub fn handle(frame: *InterruptFrame) void {
    switch (builtin.target.cpu.arch) {
        .x86_64 => @import("interrupt_x86.zig").handle(@ptrCast(frame)),
        else => @import("interrupt_stub.zig").handle(frame),
    }
}
