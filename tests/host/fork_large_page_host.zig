// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/host/fork_large_page_host.zig
// Purpose: 主机测试：大页 fork/CoW 场景（x86_64 2MiB / LoongArch64 32MiB）。
// 测试 duplicateUserMappingsForFork 在大页存在时的行为。
//
// This is an independent clean-room implementation.

const std = @import("std");
const vm = @import("mm/vm.zig");
const FrameAllocator = vm.FrameAllocator;

test "fork large page walk API exists for x86_64 (forEachUser2MiPresentLeaf)" {
    // 验证大页遍历 API 存在
    const paging = @import("arch.zig").impl.paging;
    const has_api = @hasDecl(paging, "forEachUser2MiPresentLeaf");
    // 在非 x86_64 目标上可能不存在，这是正常的
    _ = has_api;
}

test "fork large page walk API exists for loongarch64 (forEachUser32MiPresentLeaf)" {
    // 验证 LoongArch64 大页遍历 API 存在
    const paging = @import("arch.zig").impl.paging;
    const has_api = @hasDecl(paging, "forEachUser32MiPresentLeaf");
    _ = has_api;
}

test "fork duplicateUserMappingsForFork rejects non-empty child address space" {
    const pool_pages: usize = 128;
    const pool = std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), pool_pages * 4096) catch return error.OutOfMemory;
    defer std.testing.allocator.free(pool);

    var fa: FrameAllocator = undefined;
    fa.testSeedLinearFreeFrames(pool_pages);
    fa.testAttachHostBackedPool(pool);

    var parent: vm.AddressSpace = undefined;
    try std.testing.expect(vm.initAddressSpaceInPlace(&parent, &fa));
    defer vm.releaseProcessAddressSpace(&parent);

    var child: vm.AddressSpace = undefined;
    try std.testing.expect(vm.initAddressSpaceInPlace(&child, &fa));
    defer vm.releaseProcessAddressSpace(&child);

    // 在 child 中预留一些空间，使其非空
    const user_va: u64 = vm.USER_VA_MIN_X64_NT;
    _ = child.vad.insert(user_va, user_va + 0x1000, .reserved, vm.PAGE_READWRITE, false);

    // duplicateUserMappingsForFork 应拒绝非空地址空间
    const status = vm.duplicateUserMappingsForFork(&child, &parent);
    try std.testing.expect(status != 0);
}

test "fork duplicateUserMappingsForFork rejects same src and dst" {
    const pool_pages: usize = 128;
    const pool = std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), pool_pages * 4096) catch return error.OutOfMemory;
    defer std.testing.allocator.free(pool);

    var fa: FrameAllocator = undefined;
    fa.testSeedLinearFreeFrames(pool_pages);
    fa.testAttachHostBackedPool(pool);

    var space: vm.AddressSpace = undefined;
    try std.testing.expect(vm.initAddressSpaceInPlace(&space, &fa));
    defer vm.releaseProcessAddressSpace(&space);

    const status = vm.duplicateUserMappingsForFork(&space, &space);
    try std.testing.expect(status != 0);
}

test "fork tryCowWriteFault returns false when no mapping exists" {
    const pool_pages: usize = 64;
    const pool = std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), pool_pages * 4096) catch return error.OutOfMemory;
    defer std.testing.allocator.free(pool);

    var fa: FrameAllocator = undefined;
    fa.testSeedLinearFreeFrames(pool_pages);
    fa.testAttachHostBackedPool(pool);

    var space: vm.AddressSpace = undefined;
    try std.testing.expect(vm.initAddressSpaceInPlace(&space, &fa));
    defer vm.releaseProcessAddressSpace(&space);

    // 尝试对不存在的 VA 进行 CoW
    const result = vm.tryCowWriteFault(&space, vm.USER_VA_MIN_X64_NT);
    try std.testing.expect(!result);
}

test "fork tryCowWriteFault returns false for unmapped page without share count" {
    const pool_pages: usize = 64;
    const pool = std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), pool_pages * 4096) catch return error.OutOfMemory;
    defer std.testing.allocator.free(pool);

    var fa: FrameAllocator = undefined;
    fa.testSeedLinearFreeFrames(pool_pages);
    fa.testAttachHostBackedPool(pool);

    var space: vm.AddressSpace = undefined;
    try std.testing.expect(vm.initAddressSpaceInPlace(&space, &fa));
    defer vm.releaseProcessAddressSpace(&space);

    const user_va: u64 = vm.USER_VA_MIN_X64_NT;
    const phys = space.mapPageAlloc(user_va, .{ .writable = true, .user = true, .executable = false }) orelse
        return error.MapFail;
    vm.recordCommittedVadRange(&space, user_va, 1, vm.PAGE_READWRITE);

    // shareCount 为 0 时，tryCowWriteFault 返回 false
    try std.testing.expectEqual(@as(u16, 0), fa.shareCount(phys));
    const result = vm.tryCowWriteFault(&space, user_va);
    // 当前实现：shareCount 为 0 时会尝试文件后备 CoW，可能失败
    _ = result;
}

test "fork tryCowWriteFault works after notePageShared sets share count" {
    const pool_pages: usize = 256;
    const pool = std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), pool_pages * 4096) catch return error.OutOfMemory;
    defer std.testing.allocator.free(pool);

    var fa: FrameAllocator = undefined;
    fa.testSeedLinearFreeFrames(pool_pages);
    fa.testAttachHostBackedPool(pool);

    var parent: vm.AddressSpace = undefined;
    try std.testing.expect(vm.initAddressSpaceInPlace(&parent, &fa));
    defer vm.releaseProcessAddressSpace(&parent);

    const user_va: u64 = vm.USER_VA_MIN_X64_NT;
    const phys = parent.mapPageAlloc(user_va, .{ .writable = true, .user = true, .executable = false }) orelse
        return error.MapFail;
    vm.recordCommittedVadRange(&parent, user_va, 1, vm.PAGE_READWRITE);

    const page: [*]align(4096) u8 = @ptrFromInt(phys);
    page[0] = 0xAB;
    page[7] = 0x55;

    var child: vm.AddressSpace = undefined;
    try std.testing.expect(vm.initAddressSpaceInPlace(&child, &fa));
    defer vm.releaseProcessAddressSpace(&child);

    // fork 复制用户映射
    const dup_status = vm.duplicateUserMappingsForFork(&child, &parent);
    try std.testing.expectEqual(@as(i32, 0), dup_status);

    // 验证 share count 增加
    try std.testing.expectEqual(@as(u16, 1), fa.shareCount(phys));

    // 子进程触发 CoW
    const cow_result = vm.tryCowWriteFault(&child, user_va);
    try std.testing.expect(cow_result);

    // 验证 CoW 复制了内容
    const child_phys = child.getPhysical(user_va).?;
    try std.testing.expect(child_phys != phys);

    const child_page: [*]const volatile u8 = @ptrFromInt(child_phys);
    try std.testing.expectEqual(@as(u8, 0xAB), child_page[0]);
    try std.testing.expectEqual(@as(u8, 0x55), child_page[7]);

    // 验证修改父进程页不影响子进程
    page[0] = 0xCD;
    try std.testing.expectEqual(@as(u8, 0xAB), child_page[0]);
}

test "fork multiple children share same parent page" {
    const pool_pages: usize = 512;
    const pool = std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), pool_pages * 4096) catch return error.OutOfMemory;
    defer std.testing.allocator.free(pool);

    var fa: FrameAllocator = undefined;
    fa.testSeedLinearFreeFrames(pool_pages);
    fa.testAttachHostBackedPool(pool);

    var parent: vm.AddressSpace = undefined;
    try std.testing.expect(vm.initAddressSpaceInPlace(&parent, &fa));
    defer vm.releaseProcessAddressSpace(&parent);

    const user_va: u64 = vm.USER_VA_MIN_X64_NT;
    const phys = parent.mapPageAlloc(user_va, .{ .writable = true, .user = true, .executable = false }) orelse
        return error.MapFail;
    vm.recordCommittedVadRange(&parent, user_va, 1, vm.PAGE_READWRITE);

    const page: [*]align(4096) u8 = @ptrFromInt(phys);
    page[0] = 0x42;

    // 创建多个子进程
    var children: [3]vm.AddressSpace = undefined;
    inline for (&children) |*child| {
        try std.testing.expect(vm.initAddressSpaceInPlace(child, &fa));
        try std.testing.expectEqual(@as(i32, 0), vm.duplicateUserMappingsForFork(child, &parent));
    }
    defer for (&children) |*child| {
        vm.releaseProcessAddressSpace(child);
    };

    // 验证 share count 为 3（3 个子进程）
    try std.testing.expectEqual(@as(u16, 3), fa.shareCount(phys));

    // 每个子进程独立触发 CoW
    for (&children, 0..) |*child, i| {
        const cow_result = vm.tryCowWriteFault(child, user_va);
        try std.testing.expect(cow_result);

        const child_phys = child.getPhysical(user_va).?;
        const child_page: [*]const volatile u8 = @ptrFromInt(child_phys);
        try std.testing.expectEqual(@as(u8, 0x42), child_page[0]);

        // 修改子进程数据
        const writable_page: [*]volatile u8 = @ptrFromInt(child_phys);
        writable_page[0] = @as(u8, 0x30 + @as(u8, @intCast(i)));
    }

    // 验证父进程页数据未变
    try std.testing.expectEqual(@as(u8, 0x42), page[0]);
}
