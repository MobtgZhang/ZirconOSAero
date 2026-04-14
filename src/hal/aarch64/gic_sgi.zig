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
// Module: src/hal/aarch64/gic_sgi.zig
// Purpose: GICv2 Software Generated Interrupt (SGI) — CPU 间 IPI。
// SGI 0..15 用于软件触发，典型用途：TLB shootdown、调度器 IPI。
//
// This is an independent clean-room implementation.
// Reference: ARM IHI 0048B — GIC Architecture Specification (public).

/// GICD SGI 寄存器（per-CPU banked）
const GICD_SGIR: usize = 0xF00;

/// SGIR 字段
const SGIR_TARGET_LIST_MASK: u32 = 0x0000_FFFF;
const SGIR_TARGET_LIST_FILTER_SHIFT: u5 = 24;
const SGIR_NSATT_SHIFT: u5 = 15;
const SGIR_SGI_ID_SHIFT: u5 = 0;

/// 路由过滤
const TARGET_SPECIFIC: u32 = 0;
const TARGET_LIST: u32 = 1 << 24;
const TARGET_OTHERS: u32 = 2 << 24;

/// SGI ID：TLB shootdown IPI（SGI 0）
pub const SGI_TLB_INVALIDATE: u32 = 0;
/// SGI ID：调度器唤醒（SGI 1）
pub const SGI_WAKE: u32 = 1;
/// SGI ID：通用 IPI（SGI 2）
pub const SGI_GENERIC: u32 = 2;

/// 发送 SGI 到指定 CPU（通过 CPU target list）
/// sgi_id: SGI 编号（0..15）
/// cpu_target: 目标 CPU 的 Affinity 字段值（取 MPIDR_aff0）
pub fn sendSgiToCpu(sgi_id: u32, cpu_target: u32) void {
    const val = (cpu_target & 0xFF) |
        (@as(u32, sgi_id & 0xF) << SGIR_SGI_ID_SHIFT) |
        TARGET_SPECIFIC;
    gicdSgirWrite(val);
}

/// 发送 SGI 到所有其他 CPU（排除自身）
pub fn sendSgiToOthers(sgi_id: u32) void {
    const val = (@as(u32, sgi_id & 0xF) << SGIR_SGI_ID_SHIFT) | TARGET_OTHERS;
    gicdSgirWrite(val);
}

/// 向当前 CPU 广播 SGI（所有在线 CPU）
pub fn broadcastSgi(sgi_id: u32) void {
    sendSgiToOthers(sgi_id);
}

/// 读取 SGIR（调试用）
fn gicdSgirWrite(val: u32) void {
    const GICD_BASE: usize = 0x0800_0000;
    const ptr: *volatile u32 = @ptrFromInt(GICD_BASE + GICD_SGIR);
    ptr.* = val;
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

pub fn gicdSgirRead() u32 {
    const GICD_BASE: usize = 0x0800_0000;
    const ptr: *volatile u32 = @ptrFromInt(GICD_BASE + GICD_SGIR);
    return ptr.*;
}
