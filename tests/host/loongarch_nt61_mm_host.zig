// SPDX-License-Identifier: MIT OR Apache-2.0
// 主机：LoongArch64 NT6.1 MM 规格中的 VA 分解与 `userVaRangeAllowedLa64`（不导入 `arch/loongarch64/paging.zig`，避免宿主目标汇编）。

const std = @import("std");
const vm = @import("mm/vm.zig");

const L0_SHIFT: u6 = 36;
const L1_SHIFT: u6 = 25;
const L2_SHIFT: u6 = 14;
const INDEX_MASK: u64 = 0x7FF;

fn virtFromIndices(l0: u64, l1: u64, l2: u64) u64 {
    return (l0 << L0_SHIFT) | (l1 << L1_SHIFT) | (l2 << L2_SHIFT);
}

test "LA three-level VA decomposition matches paging.zig shifts (0x4000)" {
    // 与 `VirtAddr` 一致：VA = (i0<<36)|(i1<<25)|(i2<<14)；0x4000 为第二個 16KiB 叶（L0=0,L1=0,L2=1）。
    const va = virtFromIndices(0, 0, 1);
    try std.testing.expectEqual(@as(u64, 0x4000), va);
    try std.testing.expectEqual(@as(u64, 0), (va >> L0_SHIFT) & INDEX_MASK);
    try std.testing.expectEqual(@as(u64, 0), (va >> L1_SHIFT) & INDEX_MASK);
    try std.testing.expectEqual(@as(u64, 1), (va >> L2_SHIFT) & INDEX_MASK);
}

test "userVaRangeAllowedLa64 mirrors NT band on any host target" {
    try std.testing.expect(!vm.userVaRangeAllowedLa64(0x8000, 0x1000));
    try std.testing.expect(vm.userVaRangeAllowedLa64(vm.USER_VA_MIN_LA_NT, 0x1000));
    try std.testing.expect(vm.userVaRangeAllowedLa64(0x7FFF_FFFF_F000, 0x1000));
    try std.testing.expect(!vm.userVaRangeAllowedLa64(0x7FFF_FFFF_F000, 0x2000));
}

test "USER_VA_MIN_NT61 aliases stay aligned for ntdll/section" {
    try std.testing.expectEqual(vm.USER_VA_MIN_X64_NT, vm.USER_VA_MIN_NT61);
    try std.testing.expectEqual(vm.USER_VA_MAX_X64_NT, vm.USER_VA_MAX_NT61);
    try std.testing.expectEqual(vm.USER_VA_MIN_LA_NT, vm.USER_VA_MIN_NT61);
}

// 与 `src/arch/loongarch64/paging.zig` 中 `V`/`D`/`PLV_USER`/`NX` 数值一致（`protectLeafPage` 单测在 LA 目标上覆盖）。
test "LoongArch NT PTE bit layout anchor for host" {
    const v: u64 = 1 << 0;
    const d: u64 = 1 << 1;
    const plv_user: u64 = 3 << 2;
    const nx: u64 = @as(u64, 1) << 62;
    const ro_user = v | plv_user | nx;
    try std.testing.expect((ro_user & d) == 0);
    try std.testing.expect((ro_user & nx) != 0);
    try std.testing.expect((ro_user & plv_user) == plv_user);
}
