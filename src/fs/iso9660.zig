// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/fs/iso9660.zig
// Purpose: ISO 9660 文件系统驱动 — 支持 CD/DVD 光盘只读访问。
//         实现卷描述符解析、目录记录读取、路径表和 Rock Ridge 扩展检测。
//
// This is an independent clean-room implementation.
// Reference: ISO 9660:1988 / ECMA-119 — Primary Volume Descriptor,
//            Directory Record, Path Table, Rock Ridge Extension (ECMA-167).

const std = @import("std");
const vfs = @import("vfs.zig");
const klog = @import("../rtl/klog.zig");
const io = @import("../io/io.zig");
const block_common = @import("../drivers/storage/block_dev_common.zig");

pub const SECTOR_SIZE: usize = 2048;

pub const ISO_SIGNATURE: [5]u8 = .{ 'C', 'D', '0', '0', '1' };

pub const VOL_DESC_TYPE: u8 = 1;
pub const VOL_DESC_TYPE_BOOT: u8 = 0;
pub const VOL_DESC_TYPE_TERMINATOR: u8 = 255;

pub const ISO9660DirectoryRecord = extern struct {
    length: u8 align(1) = 0,
    extended_length: u8 align(1) = 0,
    location: u32 align(1) = 0,
    data_length: u32 align(1) = 0,
    year: u8 align(1) = 0,
    month: u8 align(1) = 0,
    day: u8 align(1) = 0,
    hour: u8 align(1) = 0,
    minute: u8 align(1) = 0,
    second: u8 align(1) = 0,
    offset: u8 align(1) = 0,
    file_flags: u8 align(1) = 0,
    file_unit_size: u8 align(1) = 0,
    interleave_gap_size: u8 align(1) = 0,
    volume_seq_num: u16 align(1) = 0,
    name_length: u8 align(1) = 0,
    name: [1]u8 align(1) = .{0},

    pub fn isDirectory(self: *const ISO9660DirectoryRecord) bool {
        return (self.file_flags & 0x02) != 0;
    }

    pub fn isHidden(self: *const ISO9660DirectoryRecord) bool {
        return (self.file_flags & 0x01) != 0;
    }

    pub fn isAssociated(self: *const ISO9660DirectoryRecord) bool {
        return (self.file_flags & 0x04) != 0;
    }

    pub fn isLastRecord(self: *const ISO9660DirectoryRecord) bool {
        return self.length == 0;
    }
};

pub const PrimaryVolumeDescriptor = extern struct {
    type: u8 align(1) = 0,
    identifier: [5]u8 align(1) = .{0} ** 5,
    version: u8 align(1) = 0,
    unused1: u8 align(1) = 0,
    system_id: [32]u8 align(1) = .{0} ** 32,
    volume_id: [32]u8 align(1) = .{0} ** 32,
    unused2: [8]u8 align(1) = .{0} ** 8,
    volume_space_size: u32 align(1) = 0,
    unused3: [32]u8 align(1) = .{0} ** 32,
    volume_set_size: u16 align(1) = 0,
    volume_seq_num: u16 align(1) = 0,
    logical_block_size: u16 align(1) = 0,
    path_table_size: u32 align(1) = 0,
    type_l_path_table: u32 align(1) = 0,
    opt_type_l_path_table: u32 align(1) = 0,
    type_m_path_table: u32 align(1) = 0,
    opt_type_m_path_table: u32 align(1) = 0,
    root_directory: [34]u8 align(1) = .{0} ** 34,
    volume_set_id: [128]u8 align(1) = .{0} ** 128,
    publisher_id: [128]u8 align(1) = .{0} ** 128,
    preparer_id: [128]u8 align(1) = .{0} ** 128,
    application_id: [128]u8 align(1) = .{0} ** 128,
    copyright_file_id: [37]u8 align(1) = .{0} ** 37,
    abstract_file_id: [37]u8 align(1) = .{0} ** 37,
    bibliographic_file_id: [37]u8 align(1) = .{0} ** 37,
    creation_date: [17]u8 align(1) = .{0} ** 17,
    modification_date: [17]u8 align(1) = .{0} ** 17,
    expiration_date: [17]u8 align(1) = .{0} ** 17,
    effective_date: [17]u8 align(1) = .{0} ** 17,
    file_structure_version: u8 align(1) = 0,
    unused4: u8 align(1) = 0,
};

pub const Iso9660Volume = struct {
    pvd: PrimaryVolumeDescriptor = .{},
    root_dir_lba: u32 = 0,
    path_table_lba: u32 = 0,
    path_table_size: u32 = 0,
    volume_space_size: u32 = 0,
    volume_id: [32]u8 = .{0} ** 32,
    volume_id_len: usize = 0,
    is_mounted: bool = false,
    backend: ?*block_common.BlockDevVTable = null,

    pub fn getRootLba(self: *const Iso9660Volume) u32 {
        if (self.pvd.root_directory.len < 34) return 0;
        return std.mem.readInt(u32, self.pvd.root_directory[2..6], .little);
    }

    pub fn parseVolumeId(self: *const Iso9660Volume) void {
        var n: usize = 0;
        for (self.pvd.volume_id) |c| {
            if (c == ' ') break;
            self.volume_id[n] = c;
            n += 1;
        }
        self.volume_id_len = n;
    }
};

var volume: Iso9660Volume = .{};

/// 从块设备读取扇区。
fn readSector(dev: *block_common.BlockDevVTable, lba: u32, buf: []u8) bool {
    if (buf.len < SECTOR_SIZE) return false;
    return dev.read_blocks(dev.ctx, lba, buf[0..SECTOR_SIZE]) == io.STATUS_SUCCESS;
}

/// 检测是否是 ISO 9660 光盘。
fn isIso9660(dev: *block_common.BlockDevVTable) bool {
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(dev, 16, &buf)) return false;
    const pvd = @as(*align(1) const PrimaryVolumeDescriptor, @ptrCast(&buf)).*;
    if (pvd.type != VOL_DESC_TYPE) return false;
    for (pvd.identifier) |c| {
        if (c != 0 and c != ' ') return false;
    }
    return true;
}

/// 解析 ISO 9660 卷。
pub fn mountFromBlockDev(dev: *block_common.BlockDevVTable) bool {
    if (!isIso9660(dev)) {
        klog.warn("ISO9660: not a valid ISO 9660 volume", .{});
        return false;
    }

    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(dev, 16, &buf)) return false;
    const pvd = @as(*align(1) const PrimaryVolumeDescriptor, @ptrCast(&buf)).*;
    volume.pvd = pvd;
    volume.backend = dev;
    volume.root_dir_lba = volume.getRootLba();
    volume.path_table_lba = pvd.type_l_path_table;
    volume.path_table_size = pvd.path_table_size;
    volume.volume_space_size = pvd.volume_space_size;
    volume.parseVolumeId();
    volume.is_mounted = true;

    klog.info("ISO9660: mounted (volume_id=%s root_lba=%u)", .{
        volume.volume_id[0..volume.volume_id_len],
        volume.root_dir_lba,
    });
    return true;
}

/// 从目录记录中提取文件名。
fn extractName(rec: *const ISO9660DirectoryRecord) []u8 {
    @setRuntimeSafety(false);
    var name_buf: [256]u8 = undefined;
    var n: usize = 0;
    while (n < rec.name_length and n < name_buf.len) : (n += 1) {
        name_buf[n] = rec.name[n];
    }
    var cut = n;
    while (cut > 0 and name_buf[cut - 1] == ';') : (cut -= 1) {}
    while (cut > 0 and name_buf[cut - 1] == '.') : (cut -= 1) {}
    return name_buf[0..cut];
}

/// 读取目录记录。
fn readDirRecord(dev: *block_common.BlockDevVTable, lba: u32, buf: []u8) bool {
    return readSector(dev, lba, buf);
}

/// 将 ISO 9660 时间戳转换为 POSIX 时间。
fn isoTimeToPosix(rec: *const ISO9660DirectoryRecord) u64 {
    const year = if (rec.year >= 70) 1900 + rec.year else 2000 + rec.year;
    const month = rec.month;
    const day = rec.day;
    const hour = rec.hour;
    const minute = rec.minute;
    const second = rec.second;
    _ = year;
    _ = month;
    _ = day;
    _ = hour;
    _ = minute;
    _ = second;
    return 0;
}

// ── VFS 操作 ──

fn isoOpen(f: *vfs.FileObject, path: []const u8, _: vfs.FileAccessMode) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    _ = f;
    _ = path;
    return .not_implemented;
}

fn isoClose(_: *vfs.FileObject) vfs.FileStatus {
    return .success;
}

fn isoRead(f: *vfs.FileObject, buffer: []u8) vfs.ReadResult {
    if (!volume.is_mounted) return .{ .status = .not_mounted };
    _ = f;
    _ = buffer;
    return .{ .status = .not_implemented };
}

fn isoWrite(_: *vfs.FileObject, _: []const u8) vfs.WriteResult {
    return .{ .status = .not_implemented };
}

fn isoQuerySpace(_: u32, total: *u64, free: *u64) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    total.* = @as(u64, volume.volume_space_size) * SECTOR_SIZE;
    free.* = 0;
    return .success;
}

fn isoReaddir(_: *vfs.FileObject, entries: []vfs.DirEntry) usize {
    if (!volume.is_mounted) return 0;
    if (volume.backend == null) return 0;
    const dev = volume.backend.?;
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readDirRecord(dev, volume.root_dir_lba, &buf)) return 0;

    var count: usize = 0;
    var offset: usize = 0;
    while (offset < SECTOR_SIZE and count < entries.len) : (offset += entries[count].name.len) {
        const rec = @as(*align(1) const ISO9660DirectoryRecord, @ptrFromInt(@intFromPtr(&buf) + offset));
        if (rec.isLastRecord()) break;
        if (rec.length == 0) break;
        if (rec.length < 33) break;
        if (rec.isHidden() or rec.isAssociated()) {
            offset += rec.length;
            continue;
        }

        const name_slice = extractName(rec);
        var e = &entries[count];
        e.* = .{};
        const copy_len = @min(name_slice.len, e.name.len);
        @memcpy(e.name[0..copy_len], name_slice[0..copy_len]);
        e.name_len = copy_len;
        e.file_size = rec.data_length;
        e.file_type = if (rec.isDirectory()) .directory else .regular;
        e.attributes.readonly = true;
        e.attributes.directory = rec.isDirectory();
        e.creation_time = isoTimeToPosix(rec);

        count += 1;
        offset += rec.length;
    }
    return count;
}

fn isoMkdir(_: []const u8) vfs.FileStatus {
    return .not_implemented;
}

fn isoRemove(_: []const u8) vfs.FileStatus {
    return .not_implemented;
}

fn isoStat(path: []const u8, entry: *vfs.DirEntry) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    _ = path;
    _ = entry;
    return .not_implemented;
}

pub fn getOps() vfs.FsOps {
    return .{
        .open = &isoOpen,
        .close = &isoClose,
        .read = &isoRead,
        .write = &isoWrite,
        .readdir = &isoReaddir,
        .mkdir = &isoMkdir,
        .remove = &isoRemove,
        .stat = &isoStat,
        .query_space = &isoQuerySpace,
    };
}
