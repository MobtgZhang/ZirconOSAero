// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/fs/fat1216.zig
// Purpose: FAT12/FAT16 文件系统驱动 — 与 FAT32 共享核心逻辑，
//         处理 12/16 位 FAT 表项解析和固定根目录区。
//
// This is an independent clean-room implementation.
// Reference: Microsoft FAT specification — FAT12/16 BPB layout, entry packing,
//           root directory fixed sector area, EOC markers.

const std = @import("std");
const vfs = @import("vfs.zig");
const klog = @import("../rtl/klog.zig");
const io = @import("../io/io.zig");
const block_common = @import("../drivers/storage/block_dev_common.zig");

pub const SECTOR_SIZE: usize = 512;

/// FAT12 EOC (end of cluster chain): 0xFF8–0xFFF。
pub const FAT12_EOC: u16 = 0x0FF8;
/// FAT16 EOC: 0xFFF8–0xFFFF。
pub const FAT16_EOC: u16 = 0xFFF8;
pub const FAT_FREE: u16 = 0x0000;
pub const FAT_BAD: u16 = 0x0FF7;

/// FAT12/16 共享的 BPB 结构（前 36 字节相同）。
pub const BPB_Fat1216 = extern struct {
    jmp_boot: [3]u8 align(1) = .{ 0, 0, 0 },
    oem_name: [8]u8 align(1) = [_]u8{0} ** 8,
    bytes_per_sector: u16 align(1) = 0,
    sectors_per_cluster: u8 align(1) = 0,
    reserved_sectors: u16 align(1) = 0,
    num_fats: u8 align(1) = 0,
    root_entry_count: u16 align(1) = 0,
    total_sectors_16: u16 align(1) = 0,
    media: u8 align(1) = 0,
    fat_size_16: u16 align(1) = 0,
    sectors_per_track: u16 align(1) = 0,
    num_heads: u16 align(1) = 0,
    hidden_sectors: u32 align(1) = 0,
    total_sectors_32: u32 align(1) = 0,
};

/// FAT12/FAT16 扩展 BPB（仅在逻辑扇区 0 偏移 36 起有效）。
pub const EBPB_Fat1216 = extern struct {
    drive_number: u8 align(1) = 0,
    reserved1: u8 align(1) = 0,
    boot_sig: u8 align(1) = 0,
    volume_id: u32 align(1) = 0,
    volume_label: [11]u8 align(1) = [_]u8{0} ** 11,
    fs_type: [8]u8 align(1) = [_]u8{0} ** 8,
};

/// 标准 8.3 目录条目（与 FAT32 共用结构）。
pub const DirEntry83 = extern struct {
    name: [8]u8 align(1) = [_]u8{0} ** 8,
    ext: [3]u8 align(1) = [_]u8{0} ** 3,
    attr: u8 align(1) = 0,
    nt_reserved: u8 align(1) = 0,
    create_time_tenth: u8 align(1) = 0,
    create_time: u16 align(1) = 0,
    create_date: u16 align(1) = 0,
    access_date: u16 align(1) = 0,
    first_cluster_hi: u16 align(1) = 0,
    write_time: u16 align(1) = 0,
    write_date: u16 align(1) = 0,
    first_cluster_lo: u16 align(1) = 0,
    file_size: u32 align(1) = 0,

    pub fn getFirstCluster(self: *const DirEntry83) u16 {
        return @as(u16, self.first_cluster_lo);
    }

    pub fn setFirstCluster(self: *DirEntry83, cluster: u16) void {
        self.first_cluster_hi = 0;
        self.first_cluster_lo = cluster;
    }

    pub fn isDirectory(self: *const DirEntry83) bool {
        return (self.attr & 0x10) != 0;
    }

    pub fn isVolumeId(self: *const DirEntry83) bool {
        return (self.attr & 0x08) != 0;
    }

    pub fn isLongName(self: *const DirEntry83) bool {
        return (self.attr & 0x0F) == 0x0F;
    }

    pub fn isFree(self: *const DirEntry83) bool {
        return self.name[0] == 0xE5 or self.name[0] == 0x00;
    }

    pub fn isEndOfDir(self: *const DirEntry83) bool {
        return self.name[0] == 0x00;
    }
};

pub const FatType = enum { fat12, fat16, unknown };

/// FAT12/16 卷上下文。
pub const Fat1216Volume = struct {
    bpb: BPB_Fat1216 = .{},
    ebpb: EBPB_Fat1216 = .{},
    fat_type: FatType = .unknown,
    fat: []u8 = &[_]u8{},
    fat_capacity: usize = 0,
    root_dir_sectors: usize = 0,
    first_data_sector: u32 = 0,
    total_data_clusters: u16 = 0,
    next_free_cluster: u16 = 2,
    is_mounted: bool = false,
    label: [11]u8 = [_]u8{0} ** 11,
    label_len: usize = 0,

    pub fn detectFatType(self: *const Fat1216Volume) FatType {
        const root_sectors = (self.bpb.root_entry_count * 32 + SECTOR_SIZE - 1) / SECTOR_SIZE;
        const fat_size = self.bpb.fat_size_16;
        if (fat_size == 0) return .unknown;
        const total_sectors = if (self.bpb.total_sectors_16 != 0)
            self.bpb.total_sectors_16
        else
            self.bpb.total_sectors_32;
        const data_sectors = total_sectors - self.bpb.reserved_sectors - (self.bpb.num_fats * fat_size) - root_sectors;
        const data_clusters: u32 = @intCast(data_sectors / self.bpb.sectors_per_cluster);
        if (data_clusters < 4085) return .fat12;
        if (data_clusters < 65525) return .fat16;
        return .unknown;
    }

    pub fn getRootDirSectors(self: *const Fat1216Volume) usize {
        return (self.bpb.root_entry_count * 32 + SECTOR_SIZE - 1) / SECTOR_SIZE;
    }

    pub fn getFirstDataSector(self: *const Fat1216Volume) u32 {
        const reserved = self.bpb.reserved_sectors;
        const fat_sectors = self.bpb.num_fats * self.bpb.fat_size_16;
        const root = @as(u32, @intCast(self.getRootDirSectors()));
        return reserved + fat_sectors + root;
    }

    /// FAT12 条目解析：每个条目占 12 位，跨字节边界存储。
    pub fn getFat12Entry(self: *const Fat1216Volume, cluster: u16) u16 {
        if (cluster >= self.fat_capacity) return FAT_FREE;
        const byte_offset = @as(usize, cluster) * 12 / 8;
        if (byte_offset + 1 >= self.fat.len) return FAT_FREE;
        const w = @as(u16, self.fat[byte_offset]) | (@as(u16, self.fat[byte_offset + 1]) << 8);
        if ((cluster & 1) != 0) {
            return (w >> 4) & 0x0FFF;
        } else {
            return w & 0x0FFF;
        }
    }

    /// FAT16 条目解析：每个条目占 16 位。
    pub fn getFat16Entry(self: *const Fat1216Volume, cluster: u16) u16 {
        const idx = @as(usize, cluster);
        if (idx * 2 + 1 >= self.fat.len) return FAT_FREE;
        return @as(*const u16, @ptrCast(self.fat.ptr + idx * 2)).*;
    }

    pub fn getFatEntry(self: *const Fat1216Volume, cluster: u16) u16 {
        return switch (self.fat_type) {
            .fat12 => self.getFat12Entry(cluster),
            .fat16 => self.getFat16Entry(cluster),
            else => FAT_FREE,
        };
    }

    pub fn clusterToSector(self: *const Fat1216Volume, cluster: u16) u32 {
        return self.first_data_sector + @as(u32, cluster - 2) * self.bpb.sectors_per_cluster;
    }

    pub fn isEoc(self: *const Fat1216Volume, entry: u16) bool {
        return switch (self.fat_type) {
            .fat12 => entry >= FAT12_EOC,
            .fat16 => entry >= FAT16_EOC,
            else => true,
        };
    }

    pub fn getFreeClusters(self: *const Fat1216Volume) u16 {
        var free: u16 = 0;
        const limit = @min(@as(u16, @intCast(self.fat_capacity)), self.total_data_clusters + 2);
        var c: u16 = 2;
        while (c < limit) : (c += 1) {
            if (self.getFatEntry(c) == FAT_FREE) free += 1;
        }
        return free;
    }

    pub fn getTotalDataClusters(self: *const Fat1216Volume) u32 {
        return self.total_data_clusters;
    }

    pub fn allocCluster(self: *Fat1216Volume) ?u16 {
        const limit = @min(@as(u16, @intCast(self.fat_capacity)), self.total_data_clusters + 2);
        var c = self.next_free_cluster;
        var attempts: u16 = 0;
        while (attempts < limit) : (attempts += 1) {
            if (c >= limit) c = 2;
            if (self.getFatEntry(c) == FAT_FREE) {
                // FAT12/16: 初始值均为 EOC
                self.setFatEntry(c, switch (self.fat_type) {
                    .fat12 => FAT12_EOC,
                    .fat16 => FAT16_EOC,
                    else => FAT16_EOC,
                });
                self.next_free_cluster = c + 1;
                return c;
            }
            c += 1;
        }
        return null;
    }

    fn setFat12Entry(self: *Fat1216Volume, cluster: u16, value: u16) void {
        if (cluster >= self.fat_capacity) return;
        const byte_offset = @as(usize, cluster) * 12 / 8;
        if (byte_offset + 1 >= self.fat.len) return;
        var w = @as(u16, self.fat[byte_offset]) | (@as(u16, self.fat[byte_offset + 1]) << 8);
        const masked = value & 0x0FFF;
        if ((cluster & 1) != 0) {
            w = (w & 0x000F) | (masked << 4);
        } else {
            w = (w & 0xF000) | masked;
        }
        self.fat[byte_offset] = @truncate(w);
        self.fat[byte_offset + 1] = @truncate(w >> 8);
    }

    fn setFat16Entry(self: *Fat1216Volume, cluster: u16, value: u16) void {
        const idx = @as(usize, cluster);
        if (idx * 2 + 1 >= self.fat.len) return;
        @memcpy(self.fat.ptr + idx * 2, std.mem.asBytes(&value));
    }

    pub fn setFatEntry(self: *Fat1216Volume, cluster: u16, value: u16) void {
        switch (self.fat_type) {
            .fat12 => self.setFat12Entry(cluster, value),
            .fat16 => self.setFat16Entry(cluster, value),
            else => {},
        }
    }

    pub fn freeClusterChain(self: *Fat1216Volume, start: u16) void {
        var cluster = start;
        while (cluster >= 2 and cluster < self.total_data_clusters + 2) {
            const next = self.getFatEntry(cluster);
            self.setFatEntry(cluster, FAT_FREE);
            if (self.isEoc(next) or next < 2) break;
            cluster = next;
        }
    }
};

var volume: Fat1216Volume = .{};

/// 从块设备读取扇区到缓冲区（需上层提供 BlockDevVTable）。
fn readSector(dev: *block_common.BlockDevVTable, lba: u32, buf: []u8) bool {
    if (buf.len < SECTOR_SIZE) return false;
    return dev.read_blocks(dev.ctx, lba, buf[0..SECTOR_SIZE]) == io.STATUS_SUCCESS;
}

/// 从 BPB 字节推断 FAT 类型。
fn inferFatTypeFromBpb(bpb: *const BPB_Fat1216) FatType {
    const root_sectors = (bpb.root_entry_count * 32 + SECTOR_SIZE - 1) / SECTOR_SIZE;
    const fat_size = bpb.fat_size_16;
    if (fat_size == 0) return .unknown;
    const total_sectors = if (bpb.total_sectors_16 != 0)
        bpb.total_sectors_16
    else
        bpb.total_sectors_32;
    const data_sectors = total_sectors - bpb.reserved_sectors - (bpb.num_fats * fat_size) - root_sectors;
    const data_clusters: u32 = @intCast(data_sectors / bpb.sectors_per_cluster);
    if (data_clusters < 4085) return .fat12;
    if (data_clusters < 65525) return .fat16;
    return .unknown;
}

/// 从块设备读取并解析 FAT12/16 卷。
pub fn mountFromBlockDev(dev: *block_common.BlockDevVTable) bool {
    var boot_sector: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(dev, 0, &boot_sector)) {
        klog.warn("FAT12/16: failed to read boot sector", .{});
        return false;
    }

    const bpb = @as(*const BPB_Fat1216, @ptrCast(&boot_sector)).*;
    const ebpb_off: usize = @sizeOf(BPB_Fat1216);
    const ebpb = @as(*const EBPB_Fat1216, @ptrCast(@as(*const u8, @ptrFromInt(@intFromPtr(&boot_sector) + ebpb_off)))).*;

    volume.bpb = bpb;
    volume.ebpb = ebpb;
    volume.fat_type = inferFatTypeFromBpb(&bpb);

    if (volume.fat_type == .unknown) {
        klog.warn("FAT12/16: unknown FAT type (clusters out of range)", .{});
        return false;
    }

    const fat_sectors = bpb.fat_size_16;
    const fat_bytes = @as(usize, fat_sectors) * SECTOR_SIZE;
    volume.fat_capacity = switch (volume.fat_type) {
        .fat12 => fat_bytes * 8 / 12,
        .fat16 => fat_bytes / 2,
        else => 0,
    };

    const fat: []u8 = @import("std").heap.page_allocator.alloc(u8, fat_bytes) catch {
        klog.warn("FAT12/16: out of memory for FAT table", .{});
        return false;
    };
    defer @import("std").heap.page_allocator.free(fat);

    var fat_buf: [SECTOR_SIZE]u8 = undefined;
    var s: u16 = 0;
    while (s < fat_sectors) : (s += 1) {
        if (!readSector(dev, bpb.reserved_sectors + s, &fat_buf)) {
            klog.warn("FAT12/16: failed to read FAT sector %u", .{s});
            return false;
        }
        @memcpy(fat[@as(usize, s) * SECTOR_SIZE..][0..SECTOR_SIZE], &fat_buf);
    }
    volume.fat = fat;
    volume.fat_capacity = fat_bytes;

    volume.root_dir_sectors = volume.getRootDirSectors();
    volume.first_data_sector = volume.getFirstDataSector();

    const root_sectors = @as(u32, @intCast(volume.root_dir_sectors));
    const total_sectors = if (bpb.total_sectors_16 != 0)
        bpb.total_sectors_16
    else
        bpb.total_sectors_32;
    const data_sectors = total_sectors - bpb.reserved_sectors - (@as(u32, bpb.num_fats) * fat_sectors) - root_sectors;
    volume.total_data_clusters = @intCast(data_sectors / bpb.sectors_per_cluster);

    @memcpy(&volume.label, &ebpb.volume_label);
    volume.label_len = 11;
    var n: usize = 0;
    while (n < 11) : (n += 1) {
        if (volume.label[n] == ' ') break;
    }
    volume.label_len = n;

    volume.next_free_cluster = 2;
    volume.is_mounted = true;

    klog.info("FAT12/16: mounted (type=%s clusters=%u free=%u)", .{
        @tagName(volume.fat_type),
        volume.total_data_clusters,
        volume.getFreeClusters(),
    });
    return true;
}

/// VFS 操作函数。

fn fat12Open(f: *vfs.FileObject, path: []const u8, _: vfs.FileAccessMode) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    var name_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') name_start = i + 1;
    }
    const filename = path[name_start..];
    if (filename.len == 0) {
        f.file_type = .directory;
        f.fs_data = 0;
        return .success;
    }
    if (findEntry(filename)) |e| {
        f.file_size = e.file_size;
        f.fs_data = e.getFirstCluster();
        if (e.isDirectory()) f.file_type = .directory;
        return .success;
    }
    return .not_found;
}

fn fat12Close(_: *vfs.FileObject) vfs.FileStatus {
    return .success;
}

fn fat12Read(f: *vfs.FileObject, buffer: []u8) vfs.ReadResult {
    if (!volume.is_mounted) return .{ .status = .not_mounted };
    _ = f;
    _ = buffer;
    return .{ .status = .not_implemented };
}

fn fat12Write(f: *vfs.FileObject, data: []const u8) vfs.WriteResult {
    if (!volume.is_mounted) return .{ .status = .not_mounted };
    _ = f;
    _ = data;
    return .{ .status = .not_implemented };
}

fn fat12QuerySpace(_: u32, total: *u64, free: *u64) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    total.* = @as(u64, volume.total_data_clusters) * @as(u64, volume.bpb.sectors_per_cluster) * SECTOR_SIZE;
    free.* = @as(u64, volume.getFreeClusters()) * @as(u64, volume.bpb.sectors_per_cluster) * SECTOR_SIZE;
    return .success;
}

fn findEntry(name: []const u8) ?*DirEntry83 {
    _ = name;
    return null;
}

fn fat12Readdir(_: *vfs.FileObject, entries: []vfs.DirEntry) usize {
    if (!volume.is_mounted) return 0;
    _ = entries;
    return 0;
}

fn fat12Mkdir(path: []const u8) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    _ = path;
    return .not_implemented;
}

fn fat12Remove(path: []const u8) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    _ = path;
    return .not_implemented;
}

fn fat12Stat(path: []const u8, entry: *vfs.DirEntry) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    _ = path;
    _ = entry;
    return .not_implemented;
}

pub fn getOps() vfs.FsOps {
    return .{
        .open = &fat12Open,
        .close = &fat12Close,
        .read = &fat12Read,
        .write = &fat12Write,
        .readdir = &fat12Readdir,
        .mkdir = &fat12Mkdir,
        .remove = &fat12Remove,
        .stat = &fat12Stat,
        .query_space = &fat12QuerySpace,
    };
}
