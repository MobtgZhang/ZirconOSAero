//! NT 6.1 user virtual address policy.

const std = @import("std");
const builtin = @import("builtin");

pub const USER_VA_MIN_NT61: u64 = 0x0000_0000_0001_0000;
pub const USER_VA_MAX_NT61: u64 = 0x0000_7FFF_FFFF_FFFF;

pub fn userVaRangeAllowedNt61(virt_base: u64, size_bytes: u64) bool {
    if (size_bytes == 0) return false;
    switch (builtin.cpu.arch) {
        .x86_64, .loongarch64, .mips64el => {},
        else => return true,
    }

    if (virt_base < USER_VA_MIN_NT61) return false;
    if (virt_base > USER_VA_MAX_NT61) return false;
    if (virt_base > std.math.maxInt(u64) - (size_bytes - 1)) return false;
    const last = virt_base + size_bytes - 1;
    return last <= USER_VA_MAX_NT61;
}
