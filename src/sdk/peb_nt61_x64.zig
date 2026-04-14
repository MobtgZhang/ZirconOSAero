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
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/sdk/peb_nt61_x64.zig
// Purpose: x64 `PEB` 前缀（公开字段 + comptime 偏移断言）；供加载器/进程创建写入用户页与主机 ABI 测。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows/win32/api/winternl/ns-winternl-peb

const std = @import("std");
const builtin = @import("builtin");

/// 与 MS Learn `PEB` 文档顺序一致的前缀（x64）；`Ldr` / `ProcessParameters` 可为 0（桩），**偏移须正确**。
pub const PebNt61X64 = extern struct {
    InheritedAddressSpace: u8 = 0,
    ReadImageFileExecOptions: u8 = 0,
    BeingDebugged: u8 = 0,
    BitField: u8 = 0,
    /// 对齐到 `HANDLE Mutant`（8 字节）。
    _pad0: [4]u8 = [_]u8{0} ** 4,
    Mutant: u64 = 0,
    ImageBaseAddress: u64 = 0,
    Ldr: u64 = 0,
    ProcessParameters: u64 = 0,
};

comptime {
    std.debug.assert(@offsetOf(PebNt61X64, "BeingDebugged") == 0x02);
    std.debug.assert(@offsetOf(PebNt61X64, "ImageBaseAddress") == 0x10);
    std.debug.assert(@offsetOf(PebNt61X64, "Ldr") == 0x18);
    std.debug.assert(@offsetOf(PebNt61X64, "ProcessParameters") == 0x20);
}

/// 每进程 PEB 占位页（与 `kuser` 0x7FFE0000 错开）；仅在内核已 `mapPageAlloc` 后向 `peb_va` 写入 [`PebNt61X64`]。
pub fn stubUserPebPageVa(pid: u32) u64 {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .loongarch64 and builtin.cpu.arch != .riscv64) return 0;
    const region_top: u64 = 0x0000_0000_7FD0_0000;
    const step: u64 = 0x10000;
    const raw = region_top +% (@as(u64, pid) *% step);
    return raw & ~@as(u64, 0xFFF);
}

/// 每调度线程槽一条 TEB 占位页（与 PEB 带分离）。
pub fn stubUserTebPageVa(scheduler_tid: usize) u64 {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .loongarch64 and builtin.cpu.arch != .riscv64) return 0;
    const region_top: u64 = 0x0000_0000_7FE0_0000;
    const step: u64 = 0x2000;
    const raw = region_top +% (@as(u64, scheduler_tid) *% step);
    return raw & ~@as(u64, 0xFFF);
}

/// 将字节写入 **已映射** 的物理帧首址（与 `memsetPhysicalPage` 相同恒等映射约定）。
pub fn writeBytesToPhysicalPage(phys: u64, bytes: []const u8) void {
    const p: [*]volatile u8 = @ptrFromInt(phys);
    for (bytes, 0..) |b, i| p[i] = b;
}

/// 将 `PebNt61X64` 写入 **页对齐** `peb_phys`（通常为 `mapPageAlloc` 返回帧）。
pub fn writePebToPhysicalPage(peb_phys: u64, image_base: u64, ldr: u64, proc_params: u64) void {
    var pe: PebNt61X64 = .{};
    pe.ImageBaseAddress = image_base;
    pe.Ldr = ldr;
    pe.ProcessParameters = proc_params;
    writeBytesToPhysicalPage(peb_phys, std.mem.asBytes(&pe));
}

test "PebNt61X64 public offsets match MS Learn x64" {
    try std.testing.expectEqual(@as(usize, 0x02), @offsetOf(PebNt61X64, "BeingDebugged"));
    try std.testing.expectEqual(@as(usize, 0x10), @offsetOf(PebNt61X64, "ImageBaseAddress"));
    try std.testing.expectEqual(@as(usize, 0x18), @offsetOf(PebNt61X64, "Ldr"));
    try std.testing.expectEqual(@as(usize, 0x20), @offsetOf(PebNt61X64, "ProcessParameters"));
}
