// SPDX-License-Identifier: MIT OR Apache-2.0
//! Side-effect imports so the linker analyzes these units even if `main.zig` does not reference them directly.
const builtin = @import("builtin");

comptime {
    // Use arch module instead of direct import to avoid module conflict
    _ = @import("../arch.zig");
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
    // HAL files are already imported through the arch module, no need to import them here
    // Importing them directly would cause module conflict since they are part of the arch module
}
