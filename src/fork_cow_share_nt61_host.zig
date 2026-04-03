// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/fork_cow_share_nt61_host.zig
// Purpose: 模块根在 `src/`，使 `mm/vm.zig` 等对 `arch`/`hal` 的 `@import` 落在同一模块内；`zig build test` 目标名仍为 **fork_cow_share_nt61_host**。
//
// This is an independent clean-room implementation.

comptime {
    if (@import("builtin").cpu.arch != .x86_64) {
        @compileError("fork_cow_share_nt61_host requires x86_64 host");
    }
}

const std = @import("std");
const vm = @import("mm/vm.zig");
const FrameAllocator = vm.FrameAllocator;

test "duplicateUserMappingsForFork then tryCowWriteFault splits child pfn" {
    const pool_pages: usize = 256;
    const pool = std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), pool_pages * 4096) catch return error.OutOfMemory;
    defer std.testing.allocator.free(pool);

    var fa: FrameAllocator = undefined;
    fa.testSeedLinearFreeFrames(pool_pages);
    fa.testAttachHostBackedPool(pool);

    var parent: vm.AddressSpace = undefined;
    try std.testing.expect(vm.initAddressSpaceInPlace(&parent, &fa));
    defer vm.releaseProcessAddressSpace(&parent);

    const user_va: u64 = 0x40_000;
    const phys = parent.mapPageAlloc(user_va, .{ .writable = true, .user = true, .executable = false }) orelse
        return error.ParentMapFail;
    vm.recordCommittedVadRange(&parent, user_va, 1, vm.PAGE_READWRITE);

    const page: [*]align(4096) u8 = @ptrFromInt(phys);
    page[0] = 0xAB;
    page[7] = 0x55;

    var child: vm.AddressSpace = undefined;
    try std.testing.expect(vm.initAddressSpaceInPlace(&child, &fa));
    defer vm.releaseProcessAddressSpace(&child);

    try std.testing.expectEqual(@as(i32, 0), vm.duplicateUserMappingsForFork(&child, &parent));

    const child_phys_before = child.getPhysical(user_va).?;
    try std.testing.expectEqual(phys, child_phys_before);
    // fork 路径对每个共享用户叶调用一次 `notePageShared`（与父首映射不计数配对后应为 1）。
    try std.testing.expectEqual(@as(u16, 1), fa.shareCount(phys));

    try std.testing.expect(vm.tryCowWriteFault(&child, user_va));
    const child_phys_after = child.getPhysical(user_va).?;
    try std.testing.expect(child_phys_after != phys);

    const child_page: [*]const volatile u8 = @ptrFromInt(child_phys_after);
    try std.testing.expectEqual(@as(u8, 0xAB), child_page[0]);
    try std.testing.expectEqual(@as(u8, 0x55), child_page[7]);

    page[0] = 0xCD;
    try std.testing.expectEqual(@as(u8, 0xAB), child_page[0]);
}
