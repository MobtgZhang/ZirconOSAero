// SPDX-License-Identifier: MIT OR Apache-2.0
// Host test: MIPS64EL NT6.1 MM VA policy and PTE layout (no freestanding assembly).

const std = @import("std");
const vm = @import("mm/vm.zig");

const L0_SHIFT: u6 = 30;
const L1_SHIFT: u6 = 21;
const L2_SHIFT: u6 = 12;
const INDEX_MASK: u64 = 0x1FF;

fn virtFromIndices(l0: u64, l1: u64, l2: u64) u64 {
    return (l0 << L0_SHIFT) | (l1 << L1_SHIFT) | (l2 << L2_SHIFT);
}

test "MIPS three-level VA decomposition matches 4KiB page" {
    const va = virtFromIndices(0, 0, 1);
    try std.testing.expectEqual(@as(u64, 0x1000), va);
    try std.testing.expectEqual(@as(u64, 0), (va >> L0_SHIFT) & INDEX_MASK);
    try std.testing.expectEqual(@as(u64, 0), (va >> L1_SHIFT) & INDEX_MASK);
    try std.testing.expectEqual(@as(u64, 1), (va >> L2_SHIFT) & INDEX_MASK);
}

test "MIPS VA index extraction matches x86-like 512-entry tables" {
    const va: u64 = 0x00400000;
    try std.testing.expectEqual(@as(u64, 0), (va >> L0_SHIFT) & INDEX_MASK);
    try std.testing.expectEqual(@as(u64, 2), (va >> L1_SHIFT) & INDEX_MASK);
    try std.testing.expectEqual(@as(u64, 0), (va >> L2_SHIFT) & INDEX_MASK);
}

test "userVaRangeAllowedMips64 mirrors NT band" {
    try std.testing.expect(vm.userVaRangeAllowedMips64(vm.USER_VA_MIN_MIPS64_NT, 0x1000));
    try std.testing.expect(vm.userVaRangeAllowedMips64(0x7FFF_FFFF_F000, 0x1000));
    try std.testing.expect(!vm.userVaRangeAllowedMips64(0x7FFF_FFFF_F000, 0x2000));
    try std.testing.expect(!vm.userVaRangeAllowedMips64(0, 0));
}

test "MIPS PTE flag constants anchor" {
    const G: u64 = 1 << 0;
    const V: u64 = 1 << 1;
    const D: u64 = 1 << 2;
    const C_CACHED: u64 = 3 << 3;
    try std.testing.expectEqual(@as(u64, 1), G);
    try std.testing.expectEqual(@as(u64, 2), V);
    try std.testing.expectEqual(@as(u64, 4), D);
    try std.testing.expectEqual(@as(u64, 24), C_CACHED);
}

test "USER_VA constants for MIPS64 match x64 values" {
    try std.testing.expectEqual(vm.USER_VA_MIN_X64_NT, vm.USER_VA_MIN_MIPS64_NT);
    try std.testing.expectEqual(vm.USER_VA_MAX_X64_NT, vm.USER_VA_MAX_MIPS64_NT);
}
