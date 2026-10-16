// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - Unified HAL memory-map capabilities
// Upper VM code sees only these capability functions; page-table encodings and
// platform-specific bulk-map shortcuts stay here.

const builtin = @import("builtin");
const std = @import("std");
const arch = @import("../arch.zig");
const paging = arch.impl.paging;

pub const IdentityMapStats = struct {
    huge_pages: usize = 0,
    bulk_blocks: usize = 0,
    leaf_pages: usize = 0,
};

pub fn mapIdentityByteRange(
    space: anytype,
    range_start: u64,
    range_len: u64,
    flags: anytype,
    alloc_frame: anytype,
) ?IdentityMapStats {
    if (range_len == 0) return IdentityMapStats{};
    if (range_start > std.math.maxInt(u64) - range_len) return null;

    const page_size: u64 = @intCast(paging.page_size);
    var va = range_start & ~(page_size - 1);
    const range_end = range_start + range_len;
    var stats = IdentityMapStats{};
    const pflags = flags.toPagingFlags();

    while (va < range_end) {
        if (@hasDecl(paging, "map2MiBPage") and @hasDecl(paging, "HUGE_PAGE_SIZE")) {
            const huge: u64 = paging.HUGE_PAGE_SIZE;
            if ((va % huge) == 0 and va <= std.math.maxInt(u64) - huge and va + huge <= range_end) {
                if (paging.map2MiBPage(space.pml4_phys, va, va, pflags, alloc_frame, space.allocator)) {
                    stats.huge_pages += 1;
                    va += huge;
                    continue;
                }
            }
        }

        if (@hasDecl(paging, "mapIdentity32MiBlock") and @hasDecl(paging, "identity_bulk_bytes")) {
            const block: u64 = paging.identity_bulk_bytes;
            if ((va % block) == 0 and va <= std.math.maxInt(u64) - block and va + block <= range_end) {
                if (paging.mapIdentity32MiBlock(space.pml4_phys, va, pflags, alloc_frame, space.allocator)) {
                    stats.bulk_blocks += 1;
                    va += block;
                    continue;
                }
            }
        }

        if (!space.mapPage(va, va, flags)) return null;
        stats.leaf_pages += 1;
        if (va > std.math.maxInt(u64) - page_size) break;
        va += page_size;
    }

    return stats;
}

pub fn linkKernelHalfMappings(dst: anytype, kernel_space: anytype) bool {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const dst_root: *paging.PageTable = @ptrFromInt(dst.pml4_phys);
            const src_root: *paging.PageTable = @ptrFromInt(kernel_space.pml4_phys);
            var index: usize = 256;
            while (index < 512) : (index += 1) {
                dst_root.entries[index] = src_root.entries[index];
            }
            return true;
        },
        .loongarch64 => {
            const dst_root: *paging.PageTable = @ptrFromInt(dst.pml4_phys);
            const src_root: *paging.PageTable = @ptrFromInt(kernel_space.pml4_phys);
            var index: usize = paging.kernel_linked_l0_begin;
            while (index < 2048) : (index += 1) {
                dst_root.entries[index] = src_root.entries[index];
            }
            return true;
        },
        .aarch64, .mips64el => {
            const dst_root: *paging.PageTable = @ptrFromInt(dst.pml4_phys);
            const src_root: *paging.PageTable = @ptrFromInt(kernel_space.pml4_phys);
            var index: usize = paging.kernel_linked_l0_begin;
            while (index < 512) : (index += 1) {
                dst_root.entries[index] = src_root.entries[index];
            }
            return true;
        },
        else => return true,
    }
}

pub fn forkDupChildPteFlags(pte_raw: u64) u64 {
    return switch (builtin.cpu.arch) {
        .x86_64 => blk: {
            const entry: paging.PageTableEntry = @bitCast(pte_raw);
            var flags: u64 = paging.Present | paging.Accessed;
            if (entry.user) flags |= paging.User;
            if (entry.write_through) flags |= paging.WriteThrough;
            if (entry.cache_disable) flags |= paging.CacheDisable;
            if (entry.global) flags |= paging.Global;
            if (entry.dirty) flags |= paging.Dirty;
            if (entry.no_execute) flags |= paging.NoExecute;
            break :blk flags;
        },
        .loongarch64 => blk: {
            var flags = pte_raw;
            flags &= ~@as(u64, paging.D);
            flags &= ~@as(u64, paging.NR);
            flags |= paging.Present;
            break :blk flags;
        },
        .mips64el => pte_raw & ~@as(u64, paging.D_BIT),
        .aarch64 => blk: {
            var flags = pte_raw & ~@as(u64, paging.Write);
            flags |= paging.Present | paging.Accessed;
            break :blk flags;
        },
        else => pte_raw,
    };
}
