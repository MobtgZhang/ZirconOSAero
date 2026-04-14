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
// Module: src/hal/aarch64/psci.zig
// Purpose: ARM Power State Coordination Interface (PSCI) — AP 启动/停止/挂起。
// QEMU virt 支持 PSCI 0.1，通过 HVC #0 调用。
//
// This is an independent clean-room implementation.
// Reference: ARM DEN 0022D — PSCI Specification (public).

const builtin = @import("builtin");

/// PSCI 函数 ID（SMC Calling Convention）
pub const PSCI_VERSION: u64 = 0x84000000;
pub const PSCI_CPU_ON: u64 = 0x84000003;
pub const PSCI_CPU_OFF: u64 = 0x84000002;
pub const PSCI_SYSTEM_OFF: u64 = 0x84000008;
pub const PSCI_SYSTEM_RESET: u64 = 0x84000009;
pub const PSCI_AFFINITY_INFO: u64 = 0x84000007;
pub const PSCI_MIGRATE: u64 = 0x8400000D;

/// PSCI 返回值
pub const PSCI_SUCCESS: i64 = 0;
pub const PSCI_INVALID_PARAMS: i64 = -2;
pub const PSCI_INVALID_ADDRESS: i64 = -4;

/// 调用 PSCI（SMC/HVC #0）
fn psciCall(func_id: u64, arg0: u64, arg1: u64, arg2: u64) i64 {
    var result: i64 = undefined;
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .freestanding) return PSCI_INVALID_PARAMS;
    asm volatile ("hvc #0"
        : [r] "={x0}" (result),
        : [fid] "{x0}" (func_id),
          [a0] "{x1}" (arg0),
          [a1] "{x2}" (arg1),
          [a2] "{x3}" (arg2),
        : .{ .memory = true });
    return result;
}

/// 查询 PSCI 版本
pub fn version() u32 {
    const r = psciCall(PSCI_VERSION, 0, 0, 0);
    if (r < 0) return 0;
    // 版本：bits[31:16] = major, bits[15:0] = minor
    return @as(u32, @truncate(@as(u64, @bitCast(r))));
}

/// 启动指定 CPU 核心
/// target_cpu: 目标 MPIDR（使用 affine_cpu_id）
/// entry_addr: AP 入口 VA（须 4KiB 对齐）
/// context_id: 传递给 AP 的上下文参数
pub fn cpuOn(target_cpu: u64, entry_addr: u64, context_id: u64) i64 {
    return psciCall(PSCI_CPU_ON, target_cpu, entry_addr, context_id);
}

/// 请求当前 CPU 关闭
pub fn cpuOff() i64 {
    return psciCall(PSCI_CPU_OFF, 0, 0, 0);
}

/// 查询亲和性实例状态
/// target_cpu: MPIDR
/// 返回：0=上电/1=关闭
pub fn affinityInfo(target_cpu: u64) i64 {
    return psciCall(PSCI_AFFINITY_INFO, target_cpu, 0, 0);
}

/// 系统关机
pub fn systemOff() noreturn {
    _ = psciCall(PSCI_SYSTEM_OFF, 0, 0, 0);
    while (true) asm volatile ("wfi");
}

/// 系统重启
pub fn systemReset() noreturn {
    _ = psciCall(PSCI_SYSTEM_RESET, 0, 0, 0);
    while (true) asm volatile ("wfi");
}
