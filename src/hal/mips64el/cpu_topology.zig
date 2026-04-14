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
