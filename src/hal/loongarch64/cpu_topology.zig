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

//! LoongArch64 逻辑 CPU 数：通过 ACPI MADT 解析；若 RSDP 不可用则回退到 CPUCFG。
//! 与 `ke/scheduler.zig` `schedNumCpus`、`ke/percpu_sched.zig` 对齐。

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");
const acpi_core = @import("acpi_core.zig");
const madt = @import("madt.zig");

var detected_cpu_count: u32 = 0;

pub fn logicalCpuCount() u32 {
    if (builtin.cpu.arch != .loongarch64) return 1;
    if (detected_cpu_count > 0) return detected_cpu_count;
    return 1;
}

pub fn initTopology() void {
    if (builtin.cpu.arch != .loongarch64) return;
    if (builtin.os.tag != .freestanding) {
        detected_cpu_count = 1;
        return;
    }

    const cpucfg0 = cpucfgRead(0);
    const prid = cpucfg0 & 0xFFFF;
    klog.info("LoongArch SMP: PRID=0x%x", .{@as(u32, @truncate(prid))});

    // 优先通过 ACPI MADT 获取 CPU 拓扑
    if (acpi_core.g_rsdp_ok) {
        madt.loadFromAcpiCore();
        if (madt.logical_cpu_count >= 1) {
            detected_cpu_count = madt.logical_cpu_count;
            klog.info("LoongArch SMP: MADT-based CPU count = %u", .{detected_cpu_count});
            return;
        }
    }

    // 回退：设为 1 核（QEMU virt 等无完整 ACPI 场景）
    detected_cpu_count = 1;
    klog.info("LoongArch SMP: MADT unavailable, falling back to 1 CPU", .{});
}

fn cpucfgRead(idx: u32) u64 {
    if (builtin.os.tag != .freestanding) return 0;
    return asm volatile ("cpucfg %[o], %[i]"
        : [o] "=r" (-> u64),
        : [i] "r" (@as(u64, idx)),
    );
}

/// 返回当前处理器的逻辑编号（供 per-CPU ASID 等用途）。
/// 非 freestanding 或未初始化时回退为 0。
pub fn currentProcessorNumberForAsid() u32 {
    if (builtin.os.tag != .freestanding) return 0;
    const kpcr = @import("../../ke/kpcr.zig");
    return kpcr.currentProcessorNumber();
}
