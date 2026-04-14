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
// Module: src/mm/kuser_shared.zig
// Purpose: 为进程用户地址空间映射 `KUSER_SHARED_DATA` 页（只读）并写入 NT 6.1 风格版本桩。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows-hardware/drivers/ddi/ntddk/ns-ntddk-kuser_shared_data

const std = @import("std");
const builtin = @import("builtin");
const kuser_sdk = @import("../sdk/kuser_shared_nt61.zig");
const vm = @import("vm.zig");
const arch = @import("../arch.zig");
const panic_ctx = @import("../rtl/panic_context.zig");

test "KUSER_SHARED_DATA VA page aligned for user mapping" {
    try std.testing.expect((kuser_sdk.KUSER_SHARED_DATA_VA_X64 & 0xFFF) == 0);
}

/// 运行时校验：共享页已映射且 **不可写**（x64）；供进程创建路径自检。
pub fn verifyKuserMappingInAddressSpace(space: *vm.AddressSpace) bool {
    if (builtin.cpu.arch != .x86_64) return true;
    const va = kuser_sdk.KUSER_SHARED_DATA_VA_X64;
    if (space.getPhysical(va) == null) return false;
    const pg = arch.impl.paging;
    if (@hasDecl(pg, "isPageWritable") and pg.isPageWritable(space.pml4_phys, va)) return false;
    return true;
}

/// 在新进程地址空间中安装共享数据页。失败时调用方应 `releaseProcessAddressSpace`。
pub fn installInProcessAddressSpace(space: *vm.AddressSpace) bool {
    if (builtin.cpu.arch != .x86_64) return true;

    // 关中断：避免 timer/调度路径与 `panic_context` 交叠导致 phase 误判（Phase 5 首次建进程诊断）。
    arch.disableInterrupts();
    defer arch.enableInterrupts();

    panic_ctx.setPhase(0x0005_0120);
    const va = kuser_sdk.KUSER_SHARED_DATA_VA_X64;
    panic_ctx.setPhase(0x0005_0121);
    const phys = space.mapPageAlloc(va, .{
        .writable = false,
        .user = true,
        .executable = false,
    }) orelse {
        panic_ctx.setPhase(0);
        return false;
    };

    // `mapPageAlloc` 内 `allocZeroed` 已用 `memsetPhysicalPage` 清零；勿再 `page[0..4096]`（Debug 下末端地址溢出断言）。
    panic_ctx.setPhase(0x0005_0122);
    const page: [*]align(4096) u8 = @ptrFromInt(phys);
    const prefix: *align(1) kuser_sdk.KuserSharedDataPrefix = @ptrCast(page);
    prefix.TickCountMultiplier = 0x01000000;

    writeU32(page, kuser_sdk.kuser_nt_major_version_offset, 6);
    writeU32(page, kuser_sdk.kuser_nt_minor_version_offset, 1);

    panic_ctx.setPhase(0x0005_0124);
    const ok = verifyKuserMappingInAddressSpace(space);
    // 成功路径不设 0：返回后 `createProcess` 立即 setPhase(0x0013)；避免 defer/返回窗口内 getPhase()==0。
    if (!ok) panic_ctx.setPhase(0);
    return ok;
}

fn writeU32(page: [*]align(4096) u8, offset: usize, value: u32) void {
    // 避免 `offset + 4` 在 usize 上溢出（Debug 会 panic）；合法写域为 [0, 4092]。
    if (offset > 4096 - 4) return;
    // Zig 0.15：`writeInt` 需要 `*[4]u8`，不能传运行时切片。
    const p: [*]u8 = @ptrCast(page);
    const dst: *[4]u8 = @ptrCast(p + offset);
    std.mem.writeInt(u32, dst, value, .little);
}
