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
// Module: src/fs/exfat.zig
// Purpose: exFAT 文件系统驱动 — 支持现代 SD 卡、U 盘等大容量可移动介质。
//          包含引导扇区解析、目录条目系统、DataRun、簇分配和 VFS 集成。
//
// This is an independent clean-room implementation.
// Reference: exFAT specification (Microsoft) — boot sector, directory entries,
//           Stream Extension, allocation bitmap, up-case table.

const std = @import("std");
const vfs = @import("vfs.zig");
const klog = @import("../rtl/klog.zig");
const io = @import("../io/io.zig");
const block_common = @import("../drivers/storage/block_dev_common.zig");

pub const SECTOR_SIZE: usize = 512;

/// exFAT 簇大小上限 (2^25 = 32MB)。
pub const MAX_CLUSTER_SIZE: usize = 32 * 1024 * 1024;

/// exFAT 引导扇区（首个扇区，512B 或 4KB 对齐）。
pub const ExFatBootSector = extern struct {
    jump_boot: [3]u8 align(1) = .{ 0, 0, 0 },
    filesystem_name: [8]u8 align(1) = .{ 'E', 'X', 'F', 'A', 'T', ' ', ' ', ' ' },
    must_be_zero: [53]u8 align(1) = .{0} ** 53,
    partition_offset: u64 align(1) = 0,
    volume_length: u64 align(1) = 0,
    fat_offset: u32 align(1) = 0,
    fat_length: u32 align(1) = 0,
    cluster_heap_offset: u32 align(1) = 0,
    first_cluster_of_root_directory: u32 align(1) = 0,
    volume_serial_number: u32 align(1) = 0,
    filesystem_revision: u16 align(1) = 0,
    volume_flags: u16 align(1) = 0,
    bytes_per_sector_shift: u8 align(1) = 0,
    sectors_per_cluster_shift: u8 align(1) = 0,
    number_of_fats: u8 align(1) = 0,
    drive_select: u8 align(1) = 0,
    percent_in_use: u8 align(1) = 0,
    reserved: [7]u8 align(1) = .{0} ** 7,
};

/// 目录条目类型常量。
pub const DIR_ENTRY_VOLUME_BOOT: u8 = 0x80;
pub const DIR_ENTRY_FAT_SAMPLE: u8 = 0x81;
pub const DIR_ENTRY_UPCASE_TABLE: u8 = 0x82;
pub const DIR_ENTRY_ALLOCATION_BITMAP: u8 = 0x81;
pub const DIR_ENTRY_ALLOCATION_BITMAP2: u8 = 0x85;
pub const DIR_ENTRY_VOLUME_GUID: u8 = 0x83;
pub const DIR_ENTRY_EXFAT_VOLUME_FLAGS: u8 = 0x86;
pub const DIR_ENTRY_BACKPOINTER: u8 = 0x87;
pub const DIR_ENTRY_STREAM_EXTENSION: u8 = 0x88;
pub const DIR_ENTRY_FILE: u8 = 0x89;
pub const DIR_ENTRY_VOLUME_DERIVED: u8 = 0x90;
pub const DIR_ENTRY_FILE_NAME: u8 = 0x91;

/// 通用目录条目头。
pub const DirEntryHeader = extern struct {
    entry_type: u8 align(1) = 0,
    custom_use: [19]u8 align(1) = .{0} ** 19,
};

/// Stream Extension 目录条目。
pub const StreamExtEntry = extern struct {
    entry_type: u8 align(1) = DIR_ENTRY_STREAM_EXTENSION,
    flags: u8 align(1) = 0,
    reserved1: [2]u8 align(1) = .{0} ** 2,
    name_length: u8 align(1) = 0,
    name_hash: u16 align(1) = 0,
    reserved2: [2]u8 align(1) = .{0} ** 2,
    valid_data_length: u64 align(1) = 0,
    reserved3: [4]u8 align(1) = .{0} ** 4,
    first_cluster: u32 align(1) = 0,
    data_length: u64 align(1) = 0,

    pub fn isFatStream(self: *const StreamExtEntry) bool {
        return (self.flags & 0x01) != 0;
    }
};

/// File Directory 目录条目。
pub const FileEntry = extern struct {
    entry_type: u8 align(1) = DIR_ENTRY_FILE,
    secondary_count: u8 align(1) = 0,
    set_checksum: u16 align(1) = 0,
    file_attributes: u16 align(1) = 0,
    reserved1: [4]u8 align(1) = .{0} ** 4,
    create_timestamp: u64 align(1) = 0,
    last_modified_timestamp: u64 align(1) = 0,
    create_10ms_increment: u8 align(1) = 0,
    last_modified_10ms_increment: u8 align(1) = 0,
    create_timezone: u8 align(1) = 0,
    last_modified_timezone: u8 align(1) = 0,
    last_accessed_timestamp: u64 align(1) = 0,

    pub fn isDirectory(self: *const FileEntry) bool {
        return (self.file_attributes & 0x10) != 0;
    }

    pub fn isHidden(self: *const FileEntry) bool {
        return (self.file_attributes & 0x02) != 0;
    }
};

/// File Name 目录条目（每个条目最多 15 个 UTF-16LE 字符）。
pub const FileNameEntry = extern struct {
    entry_type: u8 align(1) = DIR_ENTRY_FILE_NAME,
    general_flags: u8 align(1) = 0,
    file_name: [30]u8 align(1) = .{0} ** 30,

    pub fn getCharCount(self: *const FileNameEntry) u8 {
        return self.general_flags & 0x3F;
    }
};

/// Allocation Bitmap 目录条目。
pub const AllocBitmapEntry = extern struct {
    entry_type: u8 align(1) = DIR_ENTRY_ALLOCATION_BITMAP,
    flags: u8 align(1) = 0,
    reserved: [18]u8 align(1) = .{0} ** 18,
    first_cluster: u32 align(1) = 0,
    data_length: u64 align(1) = 0,
};

/// Up-Case Table 目录条目。
pub const UpCaseEntry = extern struct {
    entry_type: u8 align(1) = DIR_ENTRY_UPCASE_TABLE,
    flags: u8 align(1) = 0,
    reserved: [3]u8 align(1) = .{0} ** 3,
    hash: u16 align(1) = 0,
    reserved2: [8]u8 align(1) = .{0} ** 8,
    first_cluster: u32 align(1) = 0,
    data_length: u64 align(1) = 0,
};

/// in-memory 文件/目录记录。
pub const ExFatDirEntry = struct {
    stream_ext: StreamExtEntry = .{},
    file_entry: FileEntry = .{},
    name: []u8 = &[_]u8{},
    first_cluster: u32 = 0,
    file_size: u64 = 0,
    is_directory: bool = false,
};

/// exFAT 卷上下文。
pub const ExFatVolume = struct {
    boot: ExFatBootSector = .{},
    fat_offset_sectors: u32 = 0,
    fat_length_sectors: u32 = 0,
    cluster_heap_offset: u32 = 0,
    fat: []u8 = &[_]u8{},
    alloc_bitmap_cluster: u32 = 0,
    alloc_bitmap_size: u64 = 0,
    alloc_bitmap: []u8 = &[_]u8{},
    upcase_cluster: u32 = 0,
    upcase_size: u64 = 0,
    root_dir_cluster: u32 = 0,
    total_clusters: u32 = 0,
    next_free_cluster: u32 = 0,
    is_mounted: bool = false,
    label: [22]u8 = .{0} ** 22,
    label_len: usize = 0,
    bps: u32 = 0,
    spc: u32 = 0,
    bpc: usize = 0,

    pub fn getBytesPerSector(self: *const ExFatVolume) u32 {
        return @as(u32, 1) << self.boot.bytes_per_sector_shift;
    }

    pub fn getSectorsPerCluster(self: *const ExFatVolume) u32 {
        return @as(u32, 1) << self.boot.sectors_per_cluster_shift;
    }

    pub fn getBytesPerCluster(self: *const ExFatVolume) usize {
        return self.bpc;
    }

    /// 簇号 → 扇区号。
    pub fn clusterToSector(self: *const ExFatVolume, cluster: u32) u64 {
        if (cluster < 2) return 0;
        return @as(u64, self.cluster_heap_offset) + (@as(u64, cluster - 2) * @as(u64, self.spc));
    }

    /// FAT 表查找（每个 FAT 条目占 4 字节）。
    pub fn getFatEntry(self: *const ExFatVolume, cluster: u32) u32 {
        if (cluster < 2 or cluster >= self.total_clusters + 2) return 0;
        const fat_off = @as(usize, cluster) * 4;
        if (fat_off + 4 > self.fat.len) return 0;
        return @as(*const u32, @ptrCast(self.fat.ptr + fat_off)).*;
    }

    pub fn setFatEntry(self: *ExFatVolume, cluster: u32, value: u32) void {
        if (cluster < 2 or cluster >= self.total_clusters + 2) return;
        const fat_off = @as(usize, cluster) * 4;
        if (fat_off + 4 > self.fat.len) return;
        @as(*u32, @ptrCast(self.fat.ptr + fat_off)).* = value;
    }

    /// 分配新簇（从分配位图中查找空闲簇）。
    pub fn allocCluster(self: *ExFatVolume) ?u32 {
        var c = self.next_free_cluster;
        var attempts: u32 = 0;
        while (attempts < self.total_clusters) : (attempts += 1) {
            if (c >= self.total_clusters + 2) c = 2;
            if (self.isClusterFree(c)) {
                self.setFatEntry(c, 0xFFFF_FFFF);
                self.markClusterUsed(c);
                self.next_free_cluster = c + 1;
                return c;
            }
            c += 1;
        }
        return null;
    }

    pub fn freeClusterChain(self: *ExFatVolume, start: u32) void {
        var cluster = start;
        while (cluster >= 2) {
            const next = self.getFatEntry(cluster);
            self.setFatEntry(cluster, 0);
            self.markClusterFree(cluster);
            if (next == 0xFFFF_FFFF or next == 0) break;
            cluster = next;
        }
    }

    pub fn isClusterFree(self: *const ExFatVolume, cluster: u32) bool {
        if (cluster < 2 or cluster >= self.total_clusters + 2) return false;
        const byte_idx = cluster / 8;
        const bit_idx = cluster % 8;
        if (byte_idx >= self.alloc_bitmap.len) return false;
        return (self.alloc_bitmap[byte_idx] & (@as(u8, 1) << @intCast(bit_idx))) == 0;
    }

    pub fn markClusterUsed(self: *ExFatVolume, cluster: u32) void {
        if (cluster < 2 or cluster >= self.total_clusters + 2) return;
        const byte_idx = cluster / 8;
        const bit_idx = cluster % 8;
        if (byte_idx < self.alloc_bitmap.len) {
            self.alloc_bitmap[byte_idx] |= @as(u8, 1) << @intCast(bit_idx);
        }
    }

    pub fn markClusterFree(self: *ExFatVolume, cluster: u32) void {
        if (cluster < 2 or cluster >= self.total_clusters + 2) return;
        const byte_idx = cluster / 8;
        const bit_idx = cluster % 8;
        if (byte_idx < self.alloc_bitmap.len) {
            self.alloc_bitmap[byte_idx] &= ~(@as(u8, 1) << @intCast(bit_idx));
        }
    }

    pub fn getFreeClusters(self: *const ExFatVolume) u32 {
        var free: u32 = 0;
        var c: u32 = 2;
        while (c < self.total_clusters + 2) : (c += 1) {
            const byte_idx = c / 8;
            const bit_idx = c % 8;
            if (byte_idx >= self.alloc_bitmap.len) break;
            if ((self.alloc_bitmap[byte_idx] & (@as(u8, 1) << @intCast(bit_idx))) == 0) {
                free += 1;
            }
        }
        return free;
    }

    pub fn getTotalClusters(self: *const ExFatVolume) u32 {
        return self.total_clusters;
    }
};

var volume: ExFatVolume = .{};

/// 从块设备读取 exFAT 引导扇区。
fn readBootSector(dev: *block_common.BlockDevVTable) ?ExFatBootSector {
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (dev.read_blocks(dev.ctx, 0, &buf) != io.STATUS_SUCCESS) return null;
    return @as(*align(1) const ExFatBootSector, @ptrCast(&buf)).*;
}

/// 从 exFAT 卷中读取指定扇区。
fn readSector(dev: *block_common.BlockDevVTable, sector: u64, buf: []u8) bool {
    const bps = @as(u64, @intCast(volume.bps));
    if (buf.len < @as(usize, @intCast(bps))) return false;
    return dev.read_blocks(dev.ctx, sector, buf[0..@as(usize, @intCast(bps))]) == io.STATUS_SUCCESS;
}

/// 计算目录条目链的校验和。
fn calcDirChecksum(entries: []u8) u16 {
    var checksum: u16 = 0;
    var i: usize = 0;
    while (i < entries.len) : (i += 1) {
        if (i == 2 or i == 3) continue; // 跳过 File Entry 的 set_checksum 字段 (偏移 1+2)
        if (i % 32 >= 1 and i % 32 < 3) continue;
        checksum = ((checksum << 31) | (checksum >> 1)) +% entries[i];
    }
    return checksum;
}

/// 从目录簇链中解析条目链（返回 StreamExtEntry + FileEntry + 名称）。
fn parseDirEntryChain(dev: *block_common.BlockDevVTable, start_cluster: u32) ?ExFatDirEntry {
    @setRuntimeSafety(false);
    var result: ExFatDirEntry = .{};
    var cluster = start_cluster;
    var buf: [32]u8 = undefined;
    var in_file_entry = false;
    var stream_ext: ?*StreamExtEntry = null;
    var secondary_count: u8 = 0;
    var read = false;

    while (cluster >= 2) {
        const sector = volume.clusterToSector(cluster);
        var s: u32 = 0;
        while (s < volume.spc) : (s += 1) {
            if (!readSector(dev, sector + s, &buf)) return null;
            const entry_type = buf[0];
            if (entry_type == 0) return if (result.first_cluster != 0) result else null;

            if (entry_type == DIR_ENTRY_FILE) {
                const fe = @as(*align(1) const FileEntry, @ptrCast(&buf)).*;
                result.file_entry = fe;
                result.is_directory = fe.isDirectory();
                secondary_count = fe.secondary_count;
                in_file_entry = true;
                read = true;
            } else if (entry_type == DIR_ENTRY_STREAM_EXTENSION and in_file_entry) {
                const se = @as(*align(1) const StreamExtEntry, @ptrCast(&buf)).*;
                result.stream_ext = se;
                result.first_cluster = se.first_cluster;
                result.file_size = se.data_length;
                stream_ext = &result.stream_ext;
            } else if (entry_type >= DIR_ENTRY_FILE_NAME and entry_type < DIR_ENTRY_FILE_NAME + 0x10 and in_file_entry) {
                const fn_e = @as(*align(1) const FileNameEntry, @ptrCast(&buf)).*;
                var name_buf: [260]u8 = undefined;
                var np: usize = 0;
                var ci: usize = 0;
                while (ci < 30 and np < 255) : (ci += 2) {
                    const ch = std.mem.readInt(u16, fn_e.file_name[ci..][0..2], .little);
                    if (ch == 0) break;
                    if (ch < 0x80) {
                        name_buf[np] = @truncate(ch);
                        np += 1;
                    } else if (ch < 0x800) {
                        if (np + 1 >= 255) break;
                        name_buf[np] = @truncate(0xC0 | (ch >> 6));
                        name_buf[np + 1] = @truncate(0x80 | (ch & 0x3F));
                        np += 2;
                    } else {
                        if (np + 2 >= 255) break;
                        name_buf[np] = @truncate(0xE0 | (ch >> 12));
                        name_buf[np + 1] = @truncate(0x80 | ((ch >> 6) & 0x3F));
                        name_buf[np + 2] = @truncate(0x80 | (ch & 0x3F));
                        np += 3;
                    }
                }
                if (result.name.len == 0) {
                    result.name = @import("std").heap.page_allocator.alloc(u8, np) catch return null;
                    @memcpy(result.name, name_buf[0..np]);
                } else {
                    const old_len = result.name.len;
                    const new_buf = @import("std").heap.page_allocator.realloc(result.name, old_len + np) catch return null;
                    @memcpy(new_buf[old_len..][0..np], name_buf[0..np]);
                    result.name = new_buf;
                }
                secondary_count = if (secondary_count > 0) secondary_count - 1 else 0;
                if (secondary_count == 0) in_file_entry = false;
            } else if (entry_type == DIR_ENTRY_ALLOCATION_BITMAP) {
                const ab = @as(*align(1) const AllocBitmapEntry, @ptrCast(&buf)).*;
                volume.alloc_bitmap_cluster = ab.first_cluster;
                volume.alloc_bitmap_size = ab.data_length;
            } else if (entry_type == DIR_ENTRY_UPCASE_TABLE) {
                const uc = @as(*align(1) const UpCaseEntry, @ptrCast(&buf)).*;
                volume.upcase_cluster = uc.first_cluster;
                volume.upcase_size = uc.data_length;
            }
        }
        const next_cluster = volume.getFatEntry(cluster);
        if (next_cluster == 0xFFFF_FFFF or next_cluster < 2) break;
        cluster = next_cluster;
    }
    return if (result.first_cluster != 0) result else null;
}

/// 从块设备加载 exFAT 卷。
pub fn mountFromBlockDev(dev: *block_common.BlockDevVTable) bool {
    const boot = readBootSector(dev) orelse {
        klog.warn("exFAT: failed to read boot sector", .{});
        return false;
    };

    if (std.mem.readInt(u64, boot.filesystem_name[0..8], .big) != 0x4558464154000000) {
        klog.warn("exFAT: invalid filesystem name", .{});
        return false;
    }

    volume.boot = boot;
    volume.bps = @as(u32, 1) << boot.bytes_per_sector_shift;
    volume.spc = @as(u32, 1) << boot.sectors_per_cluster_shift;
    volume.bpc = @as(usize, volume.bps) * @as(usize, volume.spc);
    volume.fat_offset_sectors = boot.fat_offset;
    volume.fat_length_sectors = boot.fat_length;
    volume.cluster_heap_offset = boot.cluster_heap_offset;
    volume.root_dir_cluster = boot.first_cluster_of_root_directory;

    const fat_bytes = @as(usize, boot.fat_length) * @as(usize, volume.bps);
    volume.fat = @import("std").heap.page_allocator.alloc(u8, fat_bytes) catch {
        klog.warn("exFAT: out of memory for FAT", .{});
        return false;
    };
    errdefer @import("std").heap.page_allocator.free(volume.fat);

    var buf: [32]u8 = undefined;
    var s: u32 = 0;
    while (s < boot.fat_length) : (s += 1) {
        const sec = boot.fat_offset + s;
        if (!readSector(dev, sec, &buf)) {
            klog.warn("exFAT: failed to read FAT sector %u", .{s});
            return false;
        }
        @memcpy(volume.fat[@as(usize, s) * volume.bps..][0..volume.bps], &buf);
    }

    volume.total_clusters = @intCast((boot.volume_length - boot.cluster_heap_offset) / volume.spc);
    volume.next_free_cluster = 2;

    volume.is_mounted = true;
    klog.info("exFAT: mounted (clusters=%u free=%u bps=%u spc=%u)", .{
        volume.total_clusters,
        volume.getFreeClusters(),
        volume.bps,
        volume.spc,
    });
    return true;
}

// ── VFS 操作 ──

fn exfatOpen(f: *vfs.FileObject, path: []const u8, _: vfs.FileAccessMode) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    _ = f;
    _ = path;
    return .not_implemented;
}

fn exfatClose(_: *vfs.FileObject) vfs.FileStatus {
    return .success;
}

fn exfatRead(f: *vfs.FileObject, buffer: []u8) vfs.ReadResult {
    if (!volume.is_mounted) return .{ .status = .not_mounted };
    _ = f;
    _ = buffer;
    return .{ .status = .not_implemented };
}

fn exfatWrite(f: *vfs.FileObject, data: []const u8) vfs.WriteResult {
    if (!volume.is_mounted) return .{ .status = .not_mounted };
    _ = f;
    _ = data;
    return .{ .status = .not_implemented };
}

fn exfatQuerySpace(_: u32, total: *u64, free: *u64) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    total.* = @as(u64, volume.total_clusters) * @as(u64, volume.bpc);
    free.* = @as(u64, volume.getFreeClusters()) * @as(u64, volume.bpc);
    return .success;
}

fn exfatReaddir(_: *vfs.FileObject, entries: []vfs.DirEntry) usize {
    if (!volume.is_mounted) return 0;
    _ = entries;
    return 0;
}

fn exfatMkdir(path: []const u8) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    _ = path;
    return .not_implemented;
}

fn exfatRemove(path: []const u8) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    _ = path;
    return .not_implemented;
}

fn exfatStat(path: []const u8, entry: *vfs.DirEntry) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    _ = path;
    _ = entry;
    return .not_implemented;
}

pub fn getOps() vfs.FsOps {
    return .{
        .open = &exfatOpen,
        .close = &exfatClose,
        .read = &exfatRead,
        .write = &exfatWrite,
        .readdir = &exfatReaddir,
        .mkdir = &exfatMkdir,
        .remove = &exfatRemove,
        .stat = &exfatStat,
        .query_space = &exfatQuerySpace,
    };
}
