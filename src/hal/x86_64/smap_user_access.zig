// SPDX-License-Identifier: MIT OR Apache-2.0
// SMAP：在 syscall 分发期间临时允许内核解引用用户 VA（`stac`/`clac`）。见 Intel SDM Vol.3 4.6。
const builtin = @import("builtin");
const mitigations = @import("mitigations.zig");

pub fn syscallEnterAllowUserMemory() void {
    if (builtin.cpu.arch != .x86_64) return;
    if (!mitigations.smapEnabled()) return;
    asm volatile ("stac"
        :
        :
        : .{ .memory = true });
}

pub fn syscallExitRestoreSmap() void {
    if (builtin.cpu.arch != .x86_64) return;
    if (!mitigations.smapEnabled()) return;
    asm volatile ("clac"
        :
        :
        : .{ .memory = true });
}
