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

// SPDX-License-Identifier: MIT OR Apache-2.0
// Host tests: NT x64 user VA policy + `MEMORY_BASIC_INFORMATION` section view typing.

comptime {
    if (@import("builtin").cpu.arch != .x86_64) {
        @compileError("vm_user_va_policy_nt61_host requires x86_64 host");
    }
}

const std = @import("std");
const vm = @import("../../src/mm/vm.zig");
const vad_mod = @import("../../src/mm/vad.zig");
const ssdt = @import("../../src/arch/x86_64/ssdt_nt61.zig");

test "Stage A gate anchor: NtAllocateVirtualMemory ssdt index" {
    try std.testing.expectEqual(@as(u32, 0x18), ssdt.NtAllocateVirtualMemory);
    try std.testing.expectEqual(@as(u32, 0x1B), ssdt.NtFreeVirtualMemory);
}

test "userVaRangeAllowedX64 rejects below 64KiB policy min" {
    try std.testing.expect(!vm.userVaRangeAllowedX64(0x8000, 0x1000));
    try std.testing.expect(vm.userVaRangeAllowedX64(vm.USER_VA_MIN_X64_NT, 0x1000));
}

test "userVaRangeAllowedX64 rejects span past 7FFFFFFFFFFF" {
    try std.testing.expect(vm.userVaRangeAllowedX64(0x7FFF_FFFF_F000, 0x1000));
    try std.testing.expect(!vm.userVaRangeAllowedX64(0x7FFF_FFFF_F000, 0x2000));
}

test "userVaRangeAllowedLa64 host-callable (NT band)" {
    try std.testing.expect(vm.userVaRangeAllowedLa64(vm.USER_VA_MIN_LA_NT, 0x1000));
    try std.testing.expect(!vm.userVaRangeAllowedLa64(0x5000, 0x1000));
}

test "userVaRangeAllowedNt61 on x86_64 host matches X64 policy" {
    try std.testing.expect(vm.userVaRangeAllowedNt61(vm.USER_VA_MIN_X64_NT, 0x1000));
    try std.testing.expect(!vm.userVaRangeAllowedNt61(0x8000, 0x1000));
}

test "fillMemoryBasicInformation maps section view to MEM_MAPPED or MEM_IMAGE" {
    const pool_pages: usize = 64;
    const pool = std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), pool_pages * 4096) catch return error.OutOfMemory;
    defer std.testing.allocator.free(pool);

    var fa: vm.FrameAllocator = undefined;
    fa.testSeedLinearFreeFrames(pool_pages);
    fa.testAttachHostBackedPool(pool);

    var space: vm.AddressSpace = undefined;
    try std.testing.expect(vm.initAddressSpaceInPlace(&space, &fa));
    defer vm.releaseProcessAddressSpace(&space);

    const base: u64 = 0x20000;
    _ = space.mapPageAlloc(base, .{ .writable = false, .user = true, .executable = false }) orelse return error.MapFail;
    try std.testing.expect(space.recordSectionView(base, 1, 0x1000, 0, false, vm.PAGE_READONLY));

    var mbi: vm.MemoryBasicInformation = undefined;
    vm.fillMemoryBasicInformation(&space, base, &mbi);
    try std.testing.expectEqual(vm.MEM_MAPPED, mbi.Type);
    try std.testing.expectEqual(vad_mod.MEM_COMMIT, mbi.State);

    _ = space.mapPageAlloc(0x30000, .{ .writable = false, .user = true, .executable = true }) orelse return error.Map2;
    try std.testing.expect(space.recordSectionView(0x30000, 1, 0x2000, 0, true, vm.PAGE_READONLY));
    vm.fillMemoryBasicInformation(&space, 0x30000, &mbi);
    try std.testing.expectEqual(vm.MEM_IMAGE, mbi.Type);
}
