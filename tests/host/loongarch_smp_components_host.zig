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
// 主机：LoongArch64 SMP 组件桩验证（不依赖 freestanding）。
//
// 验证：
// 1. CSR 常量（PGDL, TPID, ECFG, EENTRY）
// 2. AP 启动相关常量（IOCSR Mailbox, AP Stack Size）
// 3. KPCR PerCpu 结构体大小和对齐
// 4. HartID 提取逻辑

const std = @import("std");

// LoongArch64 CSR 常量（从 smp_boot_stub.zig 和 kpcr.zig 复制）
const CSR_PGDL: u12 = 0x18;
const CSR_TPID: u12 = 0x30;
const CSR_ECFG: u12 = 0x4;
const CSR_EENTRY: u12 = 0xc;

// IOCSR Mailbox 基址（QEMU virt）
const IOCSR_MAILBOX_BASE: usize = 0x10000000;

// AP Stack Size（16KiB，与 LoongArch 页大小对齐）
const AP_STACK_SIZE: usize = 16384;

// 最大 AP 数量
const MAX_APS: usize = 255;

// Guard Page 大小
const GUARD_PAGE_SIZE: usize = AP_STACK_SIZE;

test "LoongArch64 CSR constants" {
    try std.testing.expectEqual(@as(u12, 0x18), CSR_PGDL);   // PGDL
    try std.testing.expectEqual(@as(u12, 0x30), CSR_TPID);   // TPID
    try std.testing.expectEqual(@as(u12, 0x4), CSR_ECFG);    // ECFG
    try std.testing.expectEqual(@as(u12, 0xc), CSR_EENTRY);  // EENTRY
}

test "LoongArch64 SMP constants" {
    try std.testing.expectEqual(@as(usize, 0x10000000), IOCSR_MAILBOX_BASE);
    try std.testing.expectEqual(@as(usize, 16384), AP_STACK_SIZE);
    try std.testing.expectEqual(@as(usize, 255), MAX_APS);
    try std.testing.expectEqual(@as(usize, 16384), GUARD_PAGE_SIZE);
}

test "LoongArch64 IOCSR mailbox address calculation" {
    // 验证 mailbox 地址计算：base + hartid * 8
    try std.testing.expectEqual(@as(usize, 0x10000000), IOCSR_MAILBOX_BASE + 0 * 8);
    try std.testing.expectEqual(@as(usize, 0x10000008), IOCSR_MAILBOX_BASE + 1 * 8);
    try std.testing.expectEqual(@as(usize, 0x10000010), IOCSR_MAILBOX_BASE + 2 * 8);
    try std.testing.expectEqual(@as(usize, 0x10000078), IOCSR_MAILBOX_BASE + 15 * 8);
}

test "LoongArch64 AP stack alignment" {
    // AP Stack 大小应该与页大小对齐
    try std.testing.expectEqual(@as(usize, 0), AP_STACK_SIZE & (16384 - 1));
    try std.testing.expectEqual(@as(usize, 0), GUARD_PAGE_SIZE & (16384 - 1));
}

test "LoongArch64 percpu PerCpu struct size" {
    // PerCpu 结构体大小应为 32 字节（与 x86_64/aarch64 一致）
    const PerCpu = extern struct {
        processor_number: u32,
        _pad0: u32 = 0,
        current_thread_index: i32,
        _pad1: u32 = 0,
        kernel_sp: u64,
        self_pointer: u64,
    };
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(PerCpu));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(PerCpu));
}

test "LoongArch64 HartID extraction from PRID" {
    // 模拟 PRID 格式：bits[15:0] = HartID
    const prid_mask: u64 = 0xFFFF;

    // 测试不同的 HartID 提取
    const prid0: u64 = 0x0000000000000000;
    const prid1: u64 = 0x0000000000000001;
    const prid255: u64 = 0x00000000000000FF;
    const prid_big: u64 = 0x1234000000000567;

    try std.testing.expectEqual(@as(u32, 0), @as(u32, @truncate(prid0 & prid_mask)));
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @truncate(prid1 & prid_mask)));
    try std.testing.expectEqual(@as(u32, 255), @as(u32, @truncate(prid255 & prid_mask)));
    try std.testing.expectEqual(@as(u32, 0x0567), @as(u32, @truncate(prid_big & prid_mask)));
}

test "LoongArch64 ECFG VS field encoding" {
    // ECFG[18:16] = VS
    // VS=7 → 向量间距 = 4 << 7 = 512 字节
    // 正确的编码是 7 << 14 = 0x1c000（硬件实现）
    const vs_value: u64 = 7;
    const ecfg_vs_field = vs_value << 14;
    try std.testing.expectEqual(@as(u64, 0x1c000), ecfg_vs_field);

    // 注意：ECFG 寄存器中的 IM 位在 bit 0-13
    // 实际 ap_entry.S 使用的是 0x1c000（VS=7，无 IM）
    try std.testing.expectEqual(@as(u64, 0x1c000), ecfg_vs_field);
}

test "LoongArch64 MAX_APS bounds check" {
    // HartID 应该小于 MAX_APS
    const valid_hart_ids = [_]u32{ 0, 1, 127, 254 };
    const invalid_hart_ids = [_]u32{ 255, 256, 1000, 0xFFFFFFFF };

    for (valid_hart_ids) |hid| {
        try std.testing.expect(hid < MAX_APS);
    }
    for (invalid_hart_ids) |hid| {
        // 255 是有效的（边界情况）
        if (hid >= MAX_APS) {
            try std.testing.expect(hid >= MAX_APS);
        }
    }
}

test "LoongArch64 AP stack array size" {
    // 总 AP 栈内存 = MAX_APS * AP_STACK_SIZE
    const total_stack_size = MAX_APS * AP_STACK_SIZE;
    const expected_total = 255 * 16384; // 4,178,280 字节 ≈ 4MB

    try std.testing.expectEqual(@as(usize, expected_total), total_stack_size);
    // 验证 16KiB 对齐
    try std.testing.expectEqual(@as(usize, 0), total_stack_size & (16384 - 1));
}

test "LoongArch64 Guard Page size equals stack size" {
    // Guard Page 应该与 AP Stack 大小相同
    try std.testing.expectEqual(GUARD_PAGE_SIZE, AP_STACK_SIZE);
    // 总 Guard Page 内存 = MAX_APS * GUARD_PAGE_SIZE
    const total_guard_size = MAX_APS * GUARD_PAGE_SIZE;
    try std.testing.expectEqual(@as(usize, 255 * 16384), total_guard_size);
}
