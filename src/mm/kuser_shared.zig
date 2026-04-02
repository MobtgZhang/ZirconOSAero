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

/// 在新进程地址空间中安装共享数据页。失败时调用方应 `releaseProcessAddressSpace`。
pub fn installInProcessAddressSpace(space: *vm.AddressSpace) bool {
    if (builtin.cpu.arch != .x86_64) return true;

    const va = kuser_sdk.KUSER_SHARED_DATA_VA_X64;
    const phys = space.mapPageAlloc(va, .{
        .writable = false,
        .user = true,
        .executable = false,
    }) orelse return false;

    // SAFETY: `phys` 来自 `FrameAllocator`，内核启动路径已 identity-map 可用物理内存；
    // 写入仅在进程创建时发生，与 `probe`/`mapPage` 契约一致。
    const page: [*]align(4096) u8 = @ptrFromInt(phys);
    @memset(page[0..4096], 0);

    const prefix: *align(1) kuser_sdk.KuserSharedDataPrefix = @ptrCast(page);
    prefix.TickCountMultiplier = 0x01000000;

    writeU32(page, kuser_sdk.kuser_nt_major_version_offset, 6);
    writeU32(page, kuser_sdk.kuser_nt_minor_version_offset, 1);

    return true;
}

fn writeU32(page: [*]align(4096) u8, offset: usize, value: u32) void {
    if (offset + 4 > 4096) return;
    std.mem.writeInt(u32, page[offset..][0..4], value, .little);
}
