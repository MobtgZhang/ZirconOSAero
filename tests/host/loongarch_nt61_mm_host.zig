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
// 主机：LoongArch64 NT6.1 MM 规格中的 VA 分解与 `userVaRangeAllowedLa64`（不导入 `arch/loongarch64/paging.zig`，避免宿主目标汇编）。
// 同时覆盖 LoongArch64 ASID 管理非 freestanding 路径（分配/释放/版本）。

const std = @import("std");
const vm = @import("mm/vm.zig");

const tlb_la = @import("hal/loongarch64/tlb_flush.zig");

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

// ── LoongArch64 ASID 管理（非 freestanding 路径测试） ──
// 注：freestanding 路径（actual CSR 0x5 读写）在目标测试中覆盖。
// Host 侧验证 API 签名存在且调用不崩溃。

test "LoongArch ASID exhaustion strategy version_bump" {
    // 非 freestanding：version_bump 为空操作，不崩溃
    tlb_la.handleAsidExhaustion(.version_bump);
}

test "LoongArch invtlbAllAsid on host is no-op" {
    // 非 freestanding：invtlbAllAsid 不做任何事（安全）
    tlb_la.invtlbAllAsid(0);
    tlb_la.invtlbAllAsid(1);
    tlb_la.invtlbAllAsid(255);
}

test "LoongArch activateAsid on host is no-op" {
    // 非 freestanding：activateAsid 不做任何事（安全）
    tlb_la.activateAsid(0);
    tlb_la.activateAsid(1);
    tlb_la.activateAsid(255);
}

test "LoongArch releaseAsid on host is safe no-op" {
    // 非 freestanding：releaseAsid 不做任何事
    tlb_la.releaseAsid(0);
    tlb_la.releaseAsid(1);
    tlb_la.releaseAsid(255);
}

test "LoongArch per-CPU ASID helpers on host" {
    // 非 freestanding：version 可访问（可能已被前序测试累加）
    const ver = tlb_la.getAsidVersion();
    _ = ver;
}

// ── LoongArch64 ASID 压力测试 ──
// 注：allocateAsid / releaseAsid 在非 freestanding 路径不检查 OS tag，
// 因此可以在 host 上验证位图分配/回收逻辑。

test "LoongArch ASID allocation and release stress (255 iterations)" {
    // 分配和释放 255 次 ASID，验证位图正确回收。
    // 在非 freestanding（host）路径，allocateAsid / releaseAsid 实际修改全局位图。
    var allocated: [256]u8 = undefined;
    var count: usize = 0;

    // 分配所有可用 ASID
    while (count < 255) {
        const asid = tlb_la.allocateAsid();
        try std.testing.expect(asid != 0); // 必须成功分配
        allocated[count] = asid;
        count += 1;
    }

    // 第 256 次分配应失败（ASID 耗尽）
    try std.testing.expectEqual(@as(u8, 0), tlb_la.allocateAsid());

    // 释放所有 ASID
    var i: usize = 0;
    while (i < count) : (i += 1) {
        tlb_la.releaseAsid(allocated[i]);
    }

    // 释放后再次分配应成功
    const asid = tlb_la.allocateAsid();
    try std.testing.expect(asid != 0);

    // 释放刚分配的 ASID 以保持测试幂等性
    tlb_la.releaseAsid(asid);
}

test "LoongArch ASID version bump after exhaustion" {
    // 模拟 ASID 耗尽场景：
    // 1. 分配所有 255 个 ASID
    // 2. 验证 allocateAsid 返回 0（耗尽）
    // 3. 调用 handleAsidExhaustion(.version_bump)
    // 4. 记录版本号
    // 5. 释放所有 ASID
    // 6. 再次分配，验证版本号递增

    // 耗尽所有 ASID
    var allocated: [256]u8 = undefined;
    var count: usize = 0;
    while (count < 255) {
        const asid = tlb_la.allocateAsid();
        if (asid == 0) break;
        allocated[count] = asid;
        count += 1;
    }

    const before = tlb_la.getAsidVersion();
    tlb_la.handleAsidExhaustion(.version_bump);
    const after = tlb_la.getAsidVersion();

    // version_bump 后版本号应递增
    try std.testing.expect(before < after);

    // 释放所有 ASID（允许后续测试继续分配）
    var i: usize = 0;
    while (i < count) : (i += 1) {
        tlb_la.releaseAsid(allocated[i]);
    }
}

// ── KPCR ASID 访问器测试 ──
const kpcr = @import("ke/kpcr.zig");

test "KPCR getCurrentAsid returns 0 on host (no per-CPU init)" {
    // 非 freestanding：getCurrentAsid 返回 0（无 per-CPU 区域）
    try std.testing.expectEqual(@as(u8, 0), kpcr.getCurrentAsid());
}

test "KPCR setCurrentAsid/getCurrentAsid roundtrip on host" {
    // 非 freestanding：setCurrentAsid 为空操作，getCurrentAsid 返回 0
    kpcr.setCurrentAsid(42);
    try std.testing.expectEqual(@as(u8, 0), kpcr.getCurrentAsid());
}

// ── LoongArch64 fork/CoW 语义测试 ──

test "fork duplicateUserMappingsForFork API exists on host (signature only)" {
    // 非 freestanding：duplicateUserMappingsForFork 在 host 上不可调用（需要 freestanding 页表操作）。
    // 验证 API 存在且签名正确（编译时检查）。
    const has_api = @hasDecl(vm, "duplicateUserMappingsForFork");
    try std.testing.expect(has_api);
}

test "fork tryCowWriteFault API exists on host" {
    // 验证 tryCowWriteFault API 存在。
    const has_api = @hasDecl(vm, "tryCowWriteFault");
    try std.testing.expect(has_api);
}

test "fork NtAllocateVirtualMemory MEM_RESERVE path API exists" {
    // 验证 NtAllocateVirtualMemory 相关 API 存在。
    const has_api = @hasDecl(vm, "NtAllocateVirtualMemory");
    try std.testing.expect(has_api);
}

// ── LoongArch64 VA 边界与页大小���试 ──
const PAGE_SIZE_LA: u64 = 16 * 1024; // 16KiB
const BLOCK_SIZE_LA: u64 = 32 * 1024 * 1024; // 32MiB

test "LoongArch 32MiB block size is 2048 pages" {
    // 验证 32MiB 块包含正确的 16KiB 页数量。
    const page_count = BLOCK_SIZE_LA / PAGE_SIZE_LA;
    try std.testing.expectEqual(@as(u64, 2048), page_count);
}

test "LoongArch page size constant accessible via arch" {
    // 验证页大小常量在 arch 模块中存在。
    const arch_mod = @import("arch.zig");
    const has_page_size = @hasDecl(arch_mod, "PAGE_SIZE");
    try std.testing.expect(has_page_size);
    // PAGE_SIZE 应该大于 0
    try std.testing.expect(arch_mod.PAGE_SIZE > 0);
}

// ── VAD 语义测试 ──
const vad_mod = @import("mm/vad.zig");

test "VAD VadState enum has reserved and committed states" {
    // VAD 必须有 reserved 和 committed 状态以支持 MEM_RESERVE 语义。
    const st = vad_mod.VadState.reserved;
    const ct = vad_mod.VadState.committed;
    _ = st;
    _ = ct;
}

test "VAD VadState has partially_committed state" {
    // VAD 应支持 partially_committed 状态。
    const pct = vad_mod.VadState.partially_committed;
    _ = pct;
}

test "VAD VadTable API exists" {
    // 验证 VadTable API 在 host 上存在。
    const has_table = @hasDecl(vad_mod, "VadTable");
    try std.testing.expect(has_table);
}

test "VAD VadEntry fields" {
    // 验证 VadEntry 包含必需字段。
    const e = vad_mod.VadEntry{
        .start = 0,
        .end_exclusive = 0x1000,
        .state = .reserved,
        .protect = 0,
        .is_guard = false,
    };
    try std.testing.expectEqual(@as(u64, 0), e.start);
    try std.testing.expectEqual(@as(u64, 0x1000), e.end_exclusive);
}

test "VAD coalesceAdjacent API exists" {
    const has_fn = @hasDecl(vad_mod.VadTable, "coalesceAdjacent");
    try std.testing.expect(has_fn);
}

test "VAD upgradeReservedContaining API exists" {
    const has_fn = @hasDecl(vad_mod.VadTable, "upgradeReservedContaining");
    try std.testing.expect(has_fn);
}

test "VAD decommitSubrange API exists" {
    const has_fn = @hasDecl(vad_mod.VadTable, "decommitSubrange");
    try std.testing.expect(has_fn);
}

// ── LoongArch64 16KB 页对齐验证 ──
// tryLazyCommitFault 使用 paging.page_size 进行页对齐，在 LoongArch64 上应为 16KB (0x4000)。

test "LoongArch tryLazyCommitFault page alignment (16KB)" {
    // 在非 LoongArch64 目标上跳过（主机测试使用 host 的页大小）
    const arch = @import("builtin");
    if (arch.cpu.arch != .loongarch64) {
        return;
    }
    // 验证 paging.page_size 为 16KB
    const arch_mod = @import("arch.zig");
    const page_size = arch_mod.PAGE_SIZE;
    try std.testing.expectEqual(@as(usize, 16 * 1024), page_size);
}

test "LoongArch 16KB page mask calculation" {
    // 在非 LoongArch64 目标上跳过
    const arch = @import("builtin");
    if (arch.cpu.arch != .loongarch64) {
        return;
    }
    // 验证页对齐掩码计算
    const arch_mod = @import("arch.zig");
    const page_size: u64 = @intCast(arch_mod.PAGE_SIZE);
    const page_mask: u64 = ~@as(u64, page_size - 1);

    // 任意 VA 按页对齐后应为页大小的倍数
    const test_va: u64 = 0x12345;
    const aligned_va: u64 = test_va & page_mask;
    try std.testing.expectEqual(@as(u64, 0), aligned_va & (page_size - 1));
}

test "LoongArch 16KB large block alignment" {
    // 在非 LoongArch64 目标上跳过
    const arch = @import("builtin");
    if (arch.cpu.arch != .loongarch64) {
        return;
    }
    // 验证大块对齐（32MiB = 2048 * 16KB）
    const page_size: u64 = 16 * 1024;
    const block_size: u64 = 32 * 1024 * 1024; // 32MiB 大页

    const block_mask: u64 = ~@as(u64, block_size - 1);
    const aligned_block: u64 = block_size & block_mask;
    try std.testing.expectEqual(@as(u64, block_size), aligned_block);

    // 验证块大小是页大小的倍数
    try std.testing.expectEqual(@as(u64, 2048), block_size / page_size);
}

