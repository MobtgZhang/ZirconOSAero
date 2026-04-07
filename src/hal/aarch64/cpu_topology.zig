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
