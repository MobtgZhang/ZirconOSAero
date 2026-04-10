// SPDX-License-Identifier: MIT OR Apache-2.0
//! Side-effect imports so the linker analyzes these units even if `main.zig` does not reference them directly.
const builtin = @import("builtin");

comptime {
    switch (builtin.target.cpu.arch) {
        .aarch64 => _ = @import("../arch/aarch64/mod.zig"),
        .loongarch64 => _ = @import("../arch/loongarch64/mod.zig"),
        .riscv64 => _ = @import("../arch/riscv64/mod.zig"),
        .mips64el => _ = @import("../arch/mips64el/mod.zig"),
        else => {},
    }
    _ = @import("../mm/pool.zig");
    _ = @import("../mm/section.zig");
    _ = @import("../ke/apc.zig");
    _ = @import("../ke/wait.zig");
    _ = @import("../ke/apc_object.zig");
    _ = @import("../ke/roadmap_hooks.zig");
    _ = @import("../mm/slab.zig");
    _ = @import("../registry/regf_hive_stub.zig");
    _ = @import("../mm/phys_buddy.zig");
    _ = @import("../mm/heap_boot.zig");
    _ = @import("../mm/ex_pool.zig");
    _ = @import("../mm/probe.zig");
    _ = @import("../mm/vad.zig");
    _ = @import("../ke/irql.zig");
    _ = @import("../ke/spinlock.zig");
    _ = @import("../ke/percpu_sched.zig");
    _ = @import("../servers/csrss_skeleton.zig");
    _ = @import("../lpc/alpc_min.zig");
    _ = @import("../loader/seh_pdata_min.zig");
    if (builtin.cpu.arch == .x86_64) {
        _ = @import("../hal/x86_64/ap_entry.zig");
        _ = @import("../hal/x86_64/tlb_broadcast.zig");
        _ = @import("../hal/x86_64/ioapic_route.zig");
    }
    if (builtin.cpu.arch == .aarch64) {
        _ = @import("../arch/aarch64/traps.zig");
        _ = @import("../arch/aarch64/thread_switch.zig");
        _ = @import("../arch/aarch64/syscall_dispatch.zig");
        _ = @import("../hal/aarch64/cpu_topology.zig");
        _ = @import("../hal/aarch64/tlb_flush.zig");
        _ = @import("../hal/aarch64/smp_boot_stub.zig");
        _ = @import("../hal/aarch64/psci.zig");
        _ = @import("../hal/aarch64/gic_sgi.zig");
    }
    if (builtin.cpu.arch == .loongarch64) {
        _ = @import("../hal/loongarch64/smp_boot_stub.zig");
    }
    if (builtin.cpu.arch == .riscv64) {
        _ = @import("../hal/riscv64/smp_boot_stub.zig");
        _ = @import("../hal/riscv64/cpu_topology.zig");
        _ = @import("../hal/riscv64/sbi_hsm.zig");
        _ = @import("../hal/riscv64/fdt.zig");
        _ = @import("../hal/riscv64/percpu.zig");
        _ = @import("../hal/riscv64/sbi_timebase.zig");
    }
}
