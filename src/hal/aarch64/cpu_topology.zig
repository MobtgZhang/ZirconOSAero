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

//! AArch64 logical CPU count: read MPIDR_EL1 or ACPI MADT (GIC) for topology.
//! Aligned with `ke/scheduler.zig` `schedNumCpus`, `ke/percpu_sched.zig`.

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");

var detected_cpu_count: u32 = 0;

pub fn logicalCpuCount() u32 {
    if (builtin.cpu.arch != .aarch64) return 1;
    if (detected_cpu_count > 0) return detected_cpu_count;
    return 1;
}

pub fn initTopology() void {
    if (builtin.cpu.arch != .aarch64) return;
    if (builtin.os.tag != .freestanding) {
        detected_cpu_count = 1;
        return;
    }

    const mpidr = readMpidr();
    const aff0: u32 = @truncate(mpidr & 0xFF);
    const aff1: u32 = @truncate((mpidr >> 8) & 0xFF);
    klog.info("AArch64 SMP: MPIDR=0x%x (Aff0=%u Aff1=%u)", .{
        @as(u64, mpidr), aff0, aff1,
    });

    // QEMU virt: MPIDR does not directly expose core count; real hardware
    // needs ACPI MADT (GIC CPU Interface) parsing. Default to 1 core.
    detected_cpu_count = 1;
}

fn readMpidr() u64 {
    if (builtin.os.tag != .freestanding) return 0;
    return asm volatile ("mrs %[o], mpidr_el1"
        : [o] "=r" (-> u64),
    );
}

/// 返回当前 CPU 的 MPIDR affinity 值（低 8 位 = CPU index）
pub fn currentMpidrAffinity() u64 {
    return readMpidr();
}

/// 返回当前 CPU 的 Affinity Level 0 值（CPU 索引）
pub fn currentCpuIndex() u32 {
    const m = readMpidr();
    return @as(u32, @truncate(m & 0xFF));
}
