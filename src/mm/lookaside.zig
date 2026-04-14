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
// Module: src/mm/lookaside.zig
// Purpose: per-CPU 小对象 lookaside（固定槽位与 `pool.zig` 一致）；热路径避免全局 `pool_gate`。
//
// This is an independent clean-room implementation.
// Ref: WDK — ExInitializeNPagedLookasideList (public name / behavioral overview only).
// IRQL：与 `pool.zig` 热路径一致。`allocateNonPaged` / `allocatePaged` 均在 **各自 IRQL 约束**下可经本路径；
// PagedPool 仍须 **APC_LEVEL 以下**（由 `ex_pool` + `ke/irql` 守卫，非 DISPATCH）。

const std = @import("std");
const percpu = @import("percpu_index.zig");

pub const SLOT_COUNT: usize = 6;

/// SMP 前预留槽位；`currentCpuIndex` 越界时钳位。
pub const MAX_CPU: usize = 64;
const MAX_DEPTH: usize = 32;

/// 与 `pool.zig` 档位块首字布局一致（仅 `next` 指针）。
pub const ListNode = struct {
    next: ?*ListNode,
};

var heads: [MAX_CPU][SLOT_COUNT]?*ListNode = std.mem.zeroes([MAX_CPU][SLOT_COUNT]?*ListNode);
var depths: [MAX_CPU][SLOT_COUNT]u8 = std.mem.zeroes([MAX_CPU][SLOT_COUNT]u8);

fn cpuSlot() usize {
    const i = percpu.currentCpuIndex();
    return @min(i, MAX_CPU - 1);
}

pub fn tryPop(slot: usize) ?*ListNode {
    if (slot >= SLOT_COUNT) return null;
    const c = cpuSlot();
    const h = heads[c][slot] orelse return null;
    heads[c][slot] = h.next;
    if (depths[c][slot] > 0) depths[c][slot] -= 1;
    return h;
}

pub fn tryPush(slot: usize, node: *ListNode) bool {
    if (slot >= SLOT_COUNT) return false;
    const c = cpuSlot();
    if (depths[c][slot] >= MAX_DEPTH) return false;
    node.next = heads[c][slot];
    heads[c][slot] = node;
    depths[c][slot] += 1;
    return true;
}

pub fn depthForDebug(cpu: usize, slot: usize) u8 {
    if (cpu >= MAX_CPU or slot >= SLOT_COUNT) return 0;
    return depths[cpu][slot];
}
