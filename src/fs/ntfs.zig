//! NTFS File System Implementation (Simplified)
//! Supports basic NTFS volume operations with MFT, attribute parsing,
//! file read/write, and directory enumeration.
//! 阶段五：可靠性深化与配置存储分轨；hive/注册表烟测见 `zig build test`（`ntfs_hive_minimum_host`、`registry_zosh1_host`）。
//!
//! P1 增强：添加真实磁盘 I/O 支持 — 引导扇区解析、MFT 记录读取、DataRun 解析。

const std = @import("std");
const vfs = @import("vfs.zig");
const klog = @import("../rtl/klog.zig");
const io = @import("../io/io.zig");
const block_common = @import("../drivers/storage/block_dev_common.zig");

pub const NTFS_SIGNATURE: [4]u8 = .{ 'N', 'T', 'F', 'S' };
pub const MFT_RECORD_SIZE: usize = 1024;
pub const CLUSTER_SIZE: usize = 4096;
pub const SECTOR_SIZE: usize = 512;

pub const MFT_RECORD_IN_USE: u16 = 0x0001;
pub const MFT_RECORD_IS_DIR: u16 = 0x0002;

// Well-known MFT record numbers
pub const MFT_RECORD_MFT: u32 = 0;
pub const MFT_RECORD_MFT_MIRROR: u32 = 1;
pub const MFT_RECORD_LOG_FILE: u32 = 2;
pub const MFT_RECORD_VOLUME: u32 = 3;
pub const MFT_RECORD_ATTR_DEF: u32 = 4;
pub const MFT_RECORD_ROOT: u32 = 5;
pub const MFT_RECORD_BITMAP: u32 = 6;
pub const MFT_RECORD_BOOT: u32 = 7;
pub const MFT_RECORD_BAD_CLUSTER: u32 = 8;
pub const MFT_RECORD_SECURE: u32 = 9;
pub const MFT_RECORD_UPCASE: u32 = 10;

pub const ATTR_STANDARD_INFO: u32 = 0x10;
pub const ATTR_FILE_NAME: u32 = 0x30;
pub const ATTR_DATA: u32 = 0x80;
pub const ATTR_INDEX_ROOT: u32 = 0x90;
pub const ATTR_INDEX_ALLOCATION: u32 = 0xA0;
pub const ATTR_BITMAP: u32 = 0xB0;
pub const ATTR_END: u32 = 0xFFFFFFFF;

pub const FILE_ATTR_READONLY: u32 = 0x0001;
pub const FILE_ATTR_HIDDEN: u32 = 0x0002;
pub const FILE_ATTR_SYSTEM: u32 = 0x0004;
pub const FILE_ATTR_DIRECTORY: u32 = 0x0010;
pub const FILE_ATTR_ARCHIVE: u32 = 0x0020;
pub const FILE_ATTR_NORMAL: u32 = 0x0080;

pub const NtfsBootSector = struct {
    signature: [4]u8 = .{ 0, 0, 0, 0 },
    bytes_per_sector: u16 = 0,
    sectors_per_cluster: u8 = 0,
    mft_cluster: u64 = 0,
    mft_mirror_cluster: u64 = 0,
    clusters_per_mft_record: i8 = 0,
    clusters_per_index_record: i8 = 0,
    volume_serial: u64 = 0,
    total_sectors: u64 = 0,
};

pub const MftRecord = struct {
    signature: [4]u8 = .{ 0, 0, 0, 0 },
    record_number: u32 = 0,
    flags: u16 = 0,
    sequence_number: u16 = 0,
    base_record: u32 = 0,
    file_name: [64]u8 = [_]u8{0} ** 64,
    file_name_len: usize = 0,
    file_size: u64 = 0,
    attributes: u32 = 0,
    parent_record: u32 = 0,
    creation_time: u64 = 0,
    modification_time: u64 = 0,
    data_start_cluster: u32 = 0,
    data_length: u32 = 0,

    pub fn isInUse(self: *const MftRecord) bool {
        return (self.flags & MFT_RECORD_IN_USE) != 0;
    }

    pub fn isDirectory(self: *const MftRecord) bool {
        return (self.flags & MFT_RECORD_IS_DIR) != 0;
    }

    pub fn setInUse(self: *MftRecord) void {
        self.flags |= MFT_RECORD_IN_USE;
    }

    pub fn setDirectory(self: *MftRecord) void {
        self.flags |= MFT_RECORD_IS_DIR;
        self.attributes |= FILE_ATTR_DIRECTORY;
    }

    pub fn getName(self: *const MftRecord) []const u8 {
        return self.file_name[0..self.file_name_len];
    }
};

const MAX_MFT_RECORDS: usize = 512;
const MAX_DATA_SIZE: usize = 256 * 1024;

pub const NtfsVolume = struct {
    boot: NtfsBootSector = .{},
    mft: [MAX_MFT_RECORDS]MftRecord = [_]MftRecord{.{}} ** MAX_MFT_RECORDS,
    mft_count: usize = 0,
    data_area: [MAX_DATA_SIZE]u8 = [_]u8{0} ** MAX_DATA_SIZE,
    next_record: u32 = 0,
    next_data_cluster: u32 = 0,
    is_mounted: bool = false,
    is_disk_backed: bool = false,
    label: [32]u8 = [_]u8{0} ** 32,
    label_len: usize = 0,
    /// 块设备后端（用于真实磁盘 I/O）。
    backend: ?*block_common.BlockDevVTable = null,
    /// 簇大小（字节）。
    cluster_size: u32 = 0,
    /// MFT 起始扇区（LBA）。
    mft_start_lba: u64 = 0,
    /// 引导扇区所在的扇区（LBA），通常为 0。
    boot_sector_lba: u64 = 0,
    /// 每簇扇区数。
    sectors_per_cluster: u32 = 0,
    /// 簇位图数据。
    cluster_bitmap: []u8 = &[_]u8{},
    cluster_bitmap_clusters: u32 = 0,
    next_free_cluster: u32 = 2,

    pub fn format(self: *NtfsVolume, label: []const u8) void {
        self.boot = .{};
        self.boot.signature = NTFS_SIGNATURE;
        self.boot.bytes_per_sector = SECTOR_SIZE;
        self.boot.sectors_per_cluster = @intCast(CLUSTER_SIZE / SECTOR_SIZE);
        self.boot.mft_cluster = 4;
        self.boot.clusters_per_mft_record = -10;
        self.boot.clusters_per_index_record = -8;
        self.boot.volume_serial = 0x5A49524F4E4F5300;
        self.mft_count = 0;
        self.next_record = 16;
        self.next_data_cluster = 64;

        const copy_len = @min(label.len, self.label.len);
        @memcpy(self.label[0..copy_len], label[0..copy_len]);
        self.label_len = copy_len;

        self.createSystemRecords();
        self.is_mounted = true;

        klog.info("NTFS: Volume formatted (label='%s')", .{label});
    }

    fn createSystemRecords(self: *NtfsVolume) void {
        const system_names = [_][]const u8{
            "$MFT",     "$MFTMirr", "$LogFile", "$Volume",
            "$AttrDef", ".",        "$Bitmap",  "$Boot",
            "$BadClus", "$Secure",  "$UpCase",
        };
        for (system_names, 0..) |name, i| {
            var rec = &self.mft[i];
            rec.* = .{};
            rec.signature = .{ 'F', 'I', 'L', 'E' };
            rec.sequence_number = 1;
            rec.record_number = @intCast(i);
            rec.setInUse();
            rec.attributes = FILE_ATTR_HIDDEN | FILE_ATTR_SYSTEM;
            if (i == MFT_RECORD_ROOT) {
                rec.setDirectory();
                rec.parent_record = MFT_RECORD_ROOT;
            }
            const name_copy = @min(name.len, rec.file_name.len);
            @memcpy(rec.file_name[0..name_copy], name[0..name_copy]);
            rec.file_name_len = name_copy;
        }
        self.mft_count = system_names.len;
    }

    pub fn allocRecord(self: *NtfsVolume) ?*MftRecord {
        if (self.mft_count >= MAX_MFT_RECORDS) return null;

        var rec = &self.mft[self.mft_count];
        rec.* = .{};
        rec.signature = .{ 'F', 'I', 'L', 'E' };
        rec.sequence_number = 1;
        rec.record_number = self.next_record;
        self.next_record += 1;
        rec.setInUse();

        self.mft_count += 1;
        return rec;
    }

    pub fn allocDataCluster(self: *NtfsVolume) ?u32 {
        const cluster = self.next_data_cluster;
        if (cluster * CLUSTER_SIZE >= MAX_DATA_SIZE) return null;
        self.next_data_cluster += 1;
        return cluster;
    }

    pub fn createFile(self: *NtfsVolume, name: []const u8, parent: u32, attrs: u32) ?*MftRecord {
        const rec = self.allocRecord() orelse return null;

        const name_copy = @min(name.len, rec.file_name.len);
        @memcpy(rec.file_name[0..name_copy], name[0..name_copy]);
        rec.file_name_len = name_copy;
        rec.parent_record = parent;
        rec.attributes = attrs;

        if (self.allocDataCluster()) |cluster| {
            rec.data_start_cluster = cluster;
        }

        return rec;
    }

    pub fn createDir(self: *NtfsVolume, name: []const u8, parent: u32) ?*MftRecord {
        const rec = self.createFile(name, parent, FILE_ATTR_DIRECTORY) orelse return null;
        rec.setDirectory();
        return rec;
    }

    pub fn findFile(self: *NtfsVolume, name: []const u8, parent: u32) ?*MftRecord {
        for (self.mft[0..self.mft_count]) |*rec| {
            if (!rec.isInUse()) continue;
            if (rec.parent_record != parent and parent != 0xFFFFFFFF) continue;
            if (rec.file_name_len != name.len) continue;
            var match = true;
            for (rec.file_name[0..rec.file_name_len], name) |a, b| {
                if (toUpperN(a) != toUpperN(b)) {
                    match = false;
                    break;
                }
            }
            if (match) return rec;
        }
        return null;
    }

    pub fn deleteFile(self: *NtfsVolume, name: []const u8, parent: u32) bool {
        const rec = self.findFile(name, parent) orelse return false;
        rec.flags = 0;
        return true;
    }

    pub fn writeData(self: *NtfsVolume, cluster: u32, data: []const u8) usize {
        const offset = @as(usize, cluster) * CLUSTER_SIZE;
        if (offset >= MAX_DATA_SIZE) return 0;
        const max_write = @min(data.len, @min(CLUSTER_SIZE, MAX_DATA_SIZE - offset));
        @memcpy(self.data_area[offset..][0..max_write], data[0..max_write]);
        return max_write;
    }

    pub fn readData(self: *const NtfsVolume, cluster: u32, buffer: []u8) usize {
        const offset = @as(usize, cluster) * CLUSTER_SIZE;
        if (offset >= MAX_DATA_SIZE) return 0;
        const max_read = @min(buffer.len, @min(CLUSTER_SIZE, MAX_DATA_SIZE - offset));
        @memcpy(buffer[0..max_read], self.data_area[offset..][0..max_read]);
        return max_read;
    }

    pub fn listDir(self: *NtfsVolume, parent: u32, entries: []vfs.DirEntry) usize {
        var count: usize = 0;
        for (self.mft[0..self.mft_count]) |*rec| {
            if (count >= entries.len) break;
            if (!rec.isInUse()) continue;
            if (rec.parent_record != parent) continue;
            if (rec.file_name_len == 0) continue;
            if (rec.file_name[0] == '$') continue;

            var e = &entries[count];
            e.* = .{};
            @memcpy(e.name[0..rec.file_name_len], rec.file_name[0..rec.file_name_len]);
            e.name_len = rec.file_name_len;
            e.file_size = rec.file_size;
            e.file_type = if (rec.isDirectory()) .directory else .regular;
            e.attributes.readonly = (rec.attributes & FILE_ATTR_READONLY) != 0;
            e.attributes.hidden = (rec.attributes & FILE_ATTR_HIDDEN) != 0;
            e.attributes.system = (rec.attributes & FILE_ATTR_SYSTEM) != 0;
            e.attributes.directory = rec.isDirectory();
            count += 1;
        }
        return count;
    }

    pub fn getRecordCount(self: *const NtfsVolume) usize {
        return self.mft_count;
    }

    pub fn getFreeRecords(self: *const NtfsVolume) usize {
        return MAX_MFT_RECORDS - self.mft_count;
    }

    /// 简化 NTFS 卷：数据区上限即「总空间」近似。
    pub fn getVolumeTotalBytes(self: *const NtfsVolume) u64 {
        _ = self;
        return MAX_DATA_SIZE;
    }

    /// 已用 ≈ 下一空闲簇指针之前的数据簇（Explorer 用量条近似）。
    pub fn getVolumeFreeBytes(self: *const NtfsVolume) u64 {
        const used = @as(u64, self.next_data_cluster) * CLUSTER_SIZE;
        return self.getVolumeTotalBytes() -| used;
    }
};

fn toUpperN(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

// ── 磁盘 I/O 支持 ──

/// 从块设备读取扇区到缓冲区。
fn readSector(dev: *block_common.BlockDevVTable, lba: u64, buf: []u8) bool {
    if (buf.len < SECTOR_SIZE) return false;
    return dev.read_blocks(dev.ctx, lba, buf[0..SECTOR_SIZE]) == io.STATUS_SUCCESS;
}

/// 读取 NTFS 引导扇区。
fn readBootSector(dev: *block_common.BlockDevVTable) ?NtfsBootSector {
    var buf: [SECTOR_SIZE]u8 = undefined;
    if (!readSector(dev, 0, &buf)) return null;
    const bs = @as(*align(1) const NtfsBootSector, @ptrCast(&buf)).*;
    if (std.mem.readInt(u32, bs.signature[0..4], .little) != 0x4546584E) { // "NTFS"
        klog.warn("NTFS: invalid boot sector signature", .{});
        return null;
    }
    return bs;
}

/// 读取 MFT 记录（从磁盘）。MFT 记录大小由引导扇区的 clusters_per_mft_record 决定。
fn readMftRecordFromDisk(vol: *NtfsVolume, record_num: u32, buf: []u8) bool {
    if (vol.backend == null) return false;
    const dev = vol.backend.?;
    const rec_size = if (vol.boot.clusters_per_mft_record < 0)
        @as(usize, @intCast(-vol.boot.clusters_per_mft_record)) * SECTOR_SIZE
    else
        @as(usize, vol.boot.clusters_per_mft_record) * vol.cluster_size;
    if (buf.len < rec_size) return false;
    const mft_offset = vol.mft_start_lba + @as(u64, record_num) * @as(u64, rec_size / SECTOR_SIZE);
    return dev.read_blocks(dev.ctx, mft_offset, buf[0..rec_size]) == io.STATUS_SUCCESS;
}

/// 解析 DataRun（NTFS 属性中的非驻留数据区域描述）。
/// 返回值：实际簇号（基于起始簇的偏移）。
/// DataRun 格式: [len][offset] 变长编码，每个字节高 4 位表示该字段长度。
fn parseDataRun(data: []const u8, offset: *usize) ?u64 {
    if (offset.* >= data.len) return null;
    const header = data[offset.*];
    offset.* += 1;
    const len_len = @as(usize, header & 0x0F);
    const off_len = @as(usize, (header >> 4) & 0x0F);
    if (offset.* + len_len + off_len > data.len) return null;
    var len: u64 = 0;
    var i: usize = 0;
    while (i < len_len) : (i += 1) {
        len |= @as(u64, data[offset.* + i]) << (8 * i);
    }
    offset.* += len_len;
    var off_delta: i64 = 0;
    var j: usize = 0;
    while (j < off_len) : (j += 1) {
        off_delta |= @as(i64, data[offset.* + j]) << @as(i64, 8 * j);
    }
    offset.* += off_len;
    return len;
}

/// 从 DataRuns 中读取数据到缓冲区。
fn readFromDataRuns(vol: *NtfsVolume, runs: []const u8, file_offset: u64, buf: []u8) usize {
    var offset: usize = 0;
    var current_cluster: u64 = 0;
    var bytes_read: usize = 0;
    var remaining = file_offset;

    // 解析所有 DataRun 并累积簇号直到找到包含 file_offset 的 DataRun
    while (offset < runs.len) {
        const header = runs[offset];
        offset += 1;
        const len_len = @as(usize, header & 0x0F);
        const off_len = @as(usize, (header >> 4) & 0x0F);

        if (offset + len_len + off_len > runs.len) break;

        var len: u64 = 0;
        var i: usize = 0;
        while (i < len_len) : (i += 1) {
            len |= @as(u64, runs[offset + i]) << (8 * i);
        }
        offset += len_len;

        var off_delta: i64 = 0;
        var j: usize = 0;
        while (j < off_len) : (j += 1) {
            off_delta |= @as(i64, runs[offset + j]) << @as(i64, 8 * j);
        }
        offset += off_len;

        // 更新当前簇号（增量编码）
        if (current_cluster == 0) {
            current_cluster = @as(u64, @intCast(off_delta));
        } else {
            current_cluster += @as(u64, @intCast(off_delta));
        }

        const run_len_clusters = len;
        const run_len_bytes = run_len_clusters * @as(u64, vol.cluster_size);

        // 如果 file_offset 在这个 DataRun 中，计算实际读取位置
        if (remaining < run_len_bytes) {
            const offset_in_run = remaining;
            const cluster_offset = offset_in_run / vol.cluster_size;
            const byte_offset_in_cluster = offset_in_run % vol.cluster_size;

            // 从这个 DataRun 中读取数据
            const start_cluster = current_cluster + cluster_offset;
            var read_pos: usize = 0;

            while (read_pos < buf.len and (start_cluster * @as(u64, vol.cluster_size) + byte_offset_in_cluster + read_pos) < (start_cluster + run_len_clusters) * @as(u64, vol.cluster_size)) {
                const cluster = start_cluster + @as(u64, @intCast(read_pos / vol.cluster_size));
                const sector_lba = vol.boot_sector_lba + cluster * @as(u64, @intCast(vol.sectors_per_cluster));
                var sector_buf: [SECTOR_SIZE]u8 = undefined;

                if (vol.backend) |dev| {
                    if (dev.read_blocks(dev.ctx, sector_lba, &sector_buf) != io.STATUS_SUCCESS) {
                        break;
                    }
                } else {
                    break;
                }

                const copy_start = if (read_pos == 0) byte_offset_in_cluster else 0;
                const copy_len = @min(buf.len - read_pos, @as(usize, @intCast(vol.cluster_size - copy_start)));
                @memcpy(buf[read_pos..read_pos + copy_len], sector_buf[@as(usize, @intCast(copy_start))..][0..copy_len]);
                read_pos += copy_len;
                bytes_read += copy_len;

                if (read_pos >= buf.len) break;
            }
            break;
        } else {
            remaining -= run_len_bytes;
        }
    }

    return bytes_read;
}

// ── VFS Integration ──

var ntfs_volume: NtfsVolume = .{};

pub fn getVolume() *NtfsVolume {
    return &ntfs_volume;
}

/// 从块设备挂载 NTFS 卷。
pub fn mountFromBlockDev(dev: *block_common.BlockDevVTable) bool {
    const bs = readBootSector(dev) orelse {
        klog.warn("NTFS: failed to read boot sector", .{});
        return false;
    };
    ntfs_volume.boot = bs;
    ntfs_volume.backend = dev;
    ntfs_volume.cluster_size = @as(u32, bs.sectors_per_cluster) * SECTOR_SIZE;
    ntfs_volume.sectors_per_cluster = bs.sectors_per_cluster;
    ntfs_volume.mft_start_lba = bs.mft_cluster * @as(u64, bs.sectors_per_cluster);
    ntfs_volume.boot_sector_lba = 0; // 引导扇区在 LBA 0
    ntfs_volume.is_disk_backed = true;
    ntfs_volume.is_mounted = true;
    klog.info("NTFS: mounted (mft_cluster=%u sectors_per_cluster=%u total_sectors=%u)", .{
        bs.mft_cluster,
        bs.sectors_per_cluster,
        bs.total_sectors,
    });
    return true;
}

fn ntfsOpen(f: *vfs.FileObject, path: []const u8, _: vfs.FileAccessMode) vfs.FileStatus {
    if (!ntfs_volume.is_mounted) return .not_mounted;
    var name_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') name_start = i + 1;
    }
    const filename = path[name_start..];
    if (filename.len == 0) {
        f.file_type = .directory;
        f.fs_data = MFT_RECORD_ROOT;
        return .success;
    }
    const rec = ntfs_volume.findFile(filename, MFT_RECORD_ROOT) orelse return .not_found;
    f.file_size = rec.file_size;
    f.fs_data = rec.data_start_cluster;
    if (rec.isDirectory()) f.file_type = .directory;
    return .success;
}

fn ntfsClose(_: *vfs.FileObject) vfs.FileStatus {
    return .success;
}

fn ntfsRead(f: *vfs.FileObject, buffer: []u8) vfs.ReadResult {
    if (!ntfs_volume.is_mounted) return .{ .status = .not_mounted };
    const cluster: u32 = @intCast(f.fs_data);
    const bytes = ntfs_volume.readData(cluster, buffer);
    f.position += bytes;
    return .{ .status = .success, .bytes_read = bytes };
}

fn ntfsWrite(f: *vfs.FileObject, data: []const u8) vfs.WriteResult {
    if (!ntfs_volume.is_mounted) return .{ .status = .not_mounted };
    const cluster: u32 = @intCast(f.fs_data);
    const bytes = ntfs_volume.writeData(cluster, data);
    f.position += bytes;
    if (f.position > f.file_size) f.file_size = f.position;
    return .{ .status = .success, .bytes_written = bytes };
}

fn ntfsQuerySpace(_: u32, total: *u64, free: *u64) vfs.FileStatus {
    if (!ntfs_volume.is_mounted) return .not_mounted;
    total.* = ntfs_volume.getVolumeTotalBytes();
    free.* = ntfs_volume.getVolumeFreeBytes();
    return .success;
}

fn ntfsReaddir(f: *vfs.FileObject, entries: []vfs.DirEntry) usize {
    _ = f;
    return ntfs_volume.listDir(MFT_RECORD_ROOT, entries);
}

fn ntfsMkdir(path: []const u8) vfs.FileStatus {
    if (!ntfs_volume.is_mounted) return .not_mounted;
    var name_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') name_start = i + 1;
    }
    if (ntfs_volume.createDir(path[name_start..], MFT_RECORD_ROOT)) |_| return .success;
    return .disk_full;
}

fn ntfsRemove(path: []const u8) vfs.FileStatus {
    if (!ntfs_volume.is_mounted) return .not_mounted;
    var name_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') name_start = i + 1;
    }
    if (ntfs_volume.deleteFile(path[name_start..], MFT_RECORD_ROOT)) return .success;
    return .not_found;
}

fn ntfsStat(path: []const u8, entry: *vfs.DirEntry) vfs.FileStatus {
    if (!ntfs_volume.is_mounted) return .not_mounted;
    var name_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') name_start = i + 1;
    }
    const rec = ntfs_volume.findFile(path[name_start..], MFT_RECORD_ROOT) orelse return .not_found;
    entry.* = .{};
    entry.file_size = rec.file_size;
    entry.file_type = if (rec.isDirectory()) .directory else .regular;
    entry.attributes.directory = rec.isDirectory();
    return .success;
}

pub fn getOps() vfs.FsOps {
    return .{
        .open = &ntfsOpen,
        .close = &ntfsClose,
        .read = &ntfsRead,
        .write = &ntfsWrite,
        .readdir = &ntfsReaddir,
        .mkdir = &ntfsMkdir,
        .remove = &ntfsRemove,
        .stat = &ntfsStat,
        .query_space = &ntfsQuerySpace,
    };
}

pub fn init() void {
    ntfs_volume.format("ZirconOSAero-NTFS");

    _ = ntfs_volume.createDir("Windows", MFT_RECORD_ROOT);
    _ = ntfs_volume.createDir("System32", MFT_RECORD_ROOT);
    _ = ntfs_volume.createDir("Users", MFT_RECORD_ROOT);
    _ = ntfs_volume.createDir("Program Files", MFT_RECORD_ROOT);
    _ = ntfs_volume.createFile("pagefile.sys", MFT_RECORD_ROOT, FILE_ATTR_HIDDEN | FILE_ATTR_SYSTEM);

    _ = vfs.mount("D:\\", .ntfs, getOps(), 1, "NTFS-Data");

    klog.info("NTFS: Volume initialized (records=%u, free=%u)", .{
        ntfs_volume.getRecordCount(), ntfs_volume.getFreeRecords(),
    });
}
