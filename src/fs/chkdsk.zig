// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/fs/chkdsk.zig
// Purpose: 文件系统一致性检查工具 — 支持 FAT12/16/32 和 NTFS 的基本完整性检查。
//         实现 FAT 表一致性检查、MFT 检查和卷标记检查。
//
// This is an independent clean-room implementation.

const std = @import("std");
const vfs = @import("vfs.zig");
const klog = @import("../rtl/klog.zig");

pub const CheckResult = struct {
    errors_found: u32 = 0,
    warnings_found: u32 = 0,
    files_checked: u32 = 0,
    clusters_checked: u32 = 0,
};

/// FAT 表一致性检查结果。
pub const FatCheckResult = struct {
    bad_clusters: u32 = 0,
    orphan_chains: u32 = 0,
    cross_links: u32 = 0,
    free_clusters: u32 = 0,
    used_clusters: u32 = 0,
};

/// 检测 FAT 卷的常见错误。
pub fn checkFatVolume(fat_entries: []const u32, total_clusters: u32) FatCheckResult {
    var result: FatCheckResult = .{};

    // 统计空闲簇
    var c: u32 = 2;
    while (c < total_clusters + 2) : (c += 1) {
        const entry = fat_entries[c];
        if (entry == 0) {
            result.free_clusters += 1;
        } else if (entry == 0x0FFFFFF7 or entry == 0xFFF7) {
            result.bad_clusters += 1;
        } else {
            result.used_clusters += 1;
        }
    }

    // 检测孤儿链和交叉链接
    var cluster_refs: []u32 = &[_]u32{0} ** 65536;
    c = 2;
    while (c < total_clusters + 2) : (c += 1) {
        const entry = fat_entries[c];
        if (entry >= 2 and entry < total_clusters + 2) {
            if (cluster_refs[entry] == 0) {
                cluster_refs[entry] = 1;
            } else {
                result.cross_links += 1;
            }
        }
    }

    // 检测孤儿链起点
    c = 2;
    while (c < total_clusters + 2) : (c += 1) {
        const entry = fat_entries[c];
        if (entry >= 2 and entry < total_clusters + 2 and cluster_refs[entry] == 1) {
            var next = entry;
            while (next >= 2 and next < total_clusters + 2) {
                const n = fat_entries[next];
                if (n == next) {
                    result.orphan_chains += 1;
                    break;
                }
                if (n < 2 or n >= total_clusters + 2) break;
                next = n;
            }
        }
    }

    return result;
}

/// NTFS MFT 一致性检查。
pub fn checkNtfsMft(records: []const bool, _: usize) CheckResult {
    var result: CheckResult = .{};

    // 检查保留记录是否在用
    const reserved_records = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    for (reserved_records) |rec_num| {
        if (rec_num < records.len and !records[rec_num]) {
            result.errors_found += 1;
            klog.warn("ChkDsk: MFT record %u should be in use", .{rec_num});
        }
    }

    // 统计使用和空闲记录
    var used: u32 = 0;
    var free: u32 = 0;
    var i: usize = 0;
    while (i < records.len) : (i += 1) {
        if (records[i]) used += 1 else free += 1;
    }
    result.clusters_checked = used + free;

    return result;
}

/// 快速卷标记检查。
pub fn quickVolumeCheck(fs_type: vfs.FsType, boot_sector_magic: u16) bool {
    switch (fs_type) {
        .fat32 => {
            return boot_sector_magic == 0xAA55;
        },
        .ntfs => {
            return boot_sector_magic == 0xAA55;
        },
        else => return false,
    }
}
