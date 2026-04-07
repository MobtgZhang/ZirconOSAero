//! MIPS64EL CPU topology — Loongson 3A1000-3A4000 multi-core detection.
//! QEMU loongson3-virt defaults to 1 CPU; real hardware uses GCR or DTB.

const builtin = @import("builtin");

var detected_cpu_count: u32 = 1;
var topology_initialized: bool = false;

pub fn logicalCpuCount() u32 {
    return detected_cpu_count;
}

pub fn initTopology() void {
    if (topology_initialized) return;
    topology_initialized = true;

    if (builtin.os.tag != .freestanding) {
        detected_cpu_count = 1;
        return;
    }

    // Read CP0 PRId for processor identification
    const prid: u32 = asm ("mfc0 %[result], $15"
        : [result] "=r" (-> u32),
    );
    _ = prid;

    // For now, default to 1 core. Multi-core detection via GCR (Loongson)
    // or DTB/ACPI will be added when SMP is fully implemented.
    detected_cpu_count = 1;
}
