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

//! NT 6.1 user virtual address band checks (split from `vm.zig` for readability / host tests).
const std = @import("std");
const builtin = @import("builtin");

/// x86_64 用户态 canonical 低半区上界（文档常量；页表须与 `arch` 一致）。Ref: Intel SDM — canonical addresses.
pub const USER_VA_MAX_HINT_X86_64: u64 = 0x0000_7FFF_FFFF_FFFF;
/// NT x64 用户空间下界（含）：低于此的 VA 不用于普通用户映射（与公开文档中用户区起始约定一致）。
pub const USER_VA_MIN_X64_NT: u64 = 0x0000_0000_0001_0000;
/// NT x64 用户空间上界（含）：`0x00007FFFFFFFFFFF`。
pub const USER_VA_MAX_X64_NT: u64 = USER_VA_MAX_HINT_X86_64;

/// NT6.1.7601 用户 VA 策略上下界（LoongArch64 新世界端口与 x64 **数值**对齐；见 `docs/specs/MemoryManagement_NT61_LoongArch64_NewWorld.md`）。
pub const USER_VA_MIN_LA_NT: u64 = USER_VA_MIN_X64_NT;
pub const USER_VA_MAX_LA_NT: u64 = USER_VA_MAX_X64_NT;
pub const USER_VA_MIN_NT61: u64 = USER_VA_MIN_X64_NT;
pub const USER_VA_MAX_NT61: u64 = USER_VA_MAX_X64_NT;

/// MIPS64EL：用户态 VA 范围与 x64 数值对齐。
pub const USER_VA_MIN_MIPS64_NT: u64 = USER_VA_MIN_X64_NT;
pub const USER_VA_MAX_MIPS64_NT: u64 = USER_VA_MAX_X64_NT;

/// x86_64：区间 `[virt_base, virt_base + size_bytes)` 是否完全落在 NT 用户地址策略内；其它架构恒为 true。
pub fn userVaRangeAllowedX64(virt_base: u64, size_bytes: u64) bool {
    if (builtin.cpu.arch != .x86_64) return true;
    if (size_bytes == 0) return false;
    if (virt_base < USER_VA_MIN_X64_NT) return false;
    if (virt_base > USER_VA_MAX_X64_NT) return false;
    if (virt_base > std.math.maxInt(u64) - (size_bytes - 1)) return false;
    const last = virt_base + size_bytes - 1;
    if (last > USER_VA_MAX_X64_NT) return false;
    return true;
}

/// LoongArch64 NT6.1.7601 端口：与 `USER_VA_{MIN,MAX}_LA_NT` 一致的区间校验（可在任意主机目标调用，供测试覆盖）。
pub fn userVaRangeAllowedLa64(virt_base: u64, size_bytes: u64) bool {
    if (size_bytes == 0) return false;
    if (virt_base < USER_VA_MIN_LA_NT) return false;
    if (virt_base > USER_VA_MAX_LA_NT) return false;
    if (virt_base > std.math.maxInt(u64) - (size_bytes - 1)) return false;
    const last = virt_base + size_bytes - 1;
    if (last > USER_VA_MAX_LA_NT) return false;
    return true;
}

/// MIPS64EL：区间校验（与 LoongArch64 逻辑相同）。
pub fn userVaRangeAllowedMips64(virt_base: u64, size_bytes: u64) bool {
    if (size_bytes == 0) return false;
    if (virt_base < USER_VA_MIN_MIPS64_NT) return false;
    if (virt_base > USER_VA_MAX_MIPS64_NT) return false;
    if (virt_base > std.math.maxInt(u64) - (size_bytes - 1)) return false;
    const last = virt_base + size_bytes - 1;
    if (last > USER_VA_MAX_MIPS64_NT) return false;
    return true;
}

/// 当前编译目标架构下的 NT6.1.7601 用户 VA 策略；非 x86_64 / loongarch64 / mips64el 恒 true。
pub fn userVaRangeAllowedNt61(virt_base: u64, size_bytes: u64) bool {
    return switch (builtin.cpu.arch) {
        .x86_64 => userVaRangeAllowedX64(virt_base, size_bytes),
        .loongarch64 => userVaRangeAllowedLa64(virt_base, size_bytes),
        .mips64el => userVaRangeAllowedMips64(virt_base, size_bytes),
        else => true,
    };
}
