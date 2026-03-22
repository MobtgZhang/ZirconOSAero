//! FAT32 File System Implementation
//! Supports reading/writing FAT32 formatted volumes,
//! directory enumeration, file creation and deletion.

const vfs = @import("vfs.zig");
const klog = @import("../rtl/klog.zig");

pub const SECTOR_SIZE: usize = 512;
pub const CLUSTER_SIZE: usize = 4096;
pub const SECTORS_PER_CLUSTER: usize = CLUSTER_SIZE / SECTOR_SIZE;
pub const FAT_ENTRIES_PER_SECTOR: usize = SECTOR_SIZE / 4;

pub const FAT32_EOC: u32 = 0x0FFFFFF8;
pub const FAT32_FREE: u32 = 0x00000000;
pub const FAT32_BAD: u32 = 0x0FFFFFF7;

pub const ATTR_READ_ONLY: u8 = 0x01;
pub const ATTR_HIDDEN: u8 = 0x02;
pub const ATTR_SYSTEM: u8 = 0x04;
pub const ATTR_VOLUME_ID: u8 = 0x08;
pub const ATTR_DIRECTORY: u8 = 0x10;
pub const ATTR_ARCHIVE: u8 = 0x20;
pub const ATTR_LONG_NAME: u8 = ATTR_READ_ONLY | ATTR_HIDDEN | ATTR_SYSTEM | ATTR_VOLUME_ID;

pub const BPB = extern struct {
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

    fat_size_32: u32 align(1) = 0,
    ext_flags: u16 align(1) = 0,
    fs_version: u16 align(1) = 0,
    root_cluster: u32 align(1) = 0,
    fs_info: u16 align(1) = 0,
    backup_boot_sector: u16 align(1) = 0,
    reserved: [12]u8 align(1) = [_]u8{0} ** 12,
    drive_number: u8 align(1) = 0,
    reserved1: u8 align(1) = 0,
    boot_sig: u8 align(1) = 0,
    volume_id: u32 align(1) = 0,
    volume_label: [11]u8 align(1) = [_]u8{0} ** 11,
    fs_type: [8]u8 align(1) = [_]u8{0} ** 8,
};

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

    pub fn getFirstCluster(self: *const DirEntry83) u32 {
        return (@as(u32, self.first_cluster_hi) << 16) | @as(u32, self.first_cluster_lo);
    }

    pub fn setFirstCluster(self: *DirEntry83, cluster: u32) void {
        self.first_cluster_hi = @intCast((cluster >> 16) & 0xFFFF);
        self.first_cluster_lo = @intCast(cluster & 0xFFFF);
    }

    pub fn isDirectory(self: *const DirEntry83) bool {
        return (self.attr & ATTR_DIRECTORY) != 0;
    }

    pub fn isVolumeId(self: *const DirEntry83) bool {
        return (self.attr & ATTR_VOLUME_ID) != 0;
    }

    pub fn isLongName(self: *const DirEntry83) bool {
        return (self.attr & ATTR_LONG_NAME) == ATTR_LONG_NAME;
    }

    pub fn isFree(self: *const DirEntry83) bool {
        return self.name[0] == 0xE5 or self.name[0] == 0x00;
    }

    pub fn isEndOfDir(self: *const DirEntry83) bool {
        return self.name[0] == 0x00;
    }
};

const MAX_FAT_ENTRIES: usize = 4096;
const MAX_DATA_SECTORS: usize = 8192;
const MAX_DIR_ENTRIES: usize = 256;

pub const Fat32Volume = struct {
    bpb: BPB = .{},
    fat_table: [MAX_FAT_ENTRIES]u32 = [_]u32{0} ** MAX_FAT_ENTRIES,
    data_area: [MAX_DATA_SECTORS * SECTOR_SIZE]u8 = [_]u8{0} ** (MAX_DATA_SECTORS * SECTOR_SIZE),
    root_entries: [MAX_DIR_ENTRIES]DirEntry83 = [_]DirEntry83{.{}} ** MAX_DIR_ENTRIES,
    root_entry_count: usize = 0,
    next_free_cluster: u32 = 0,
    is_mounted: bool = false,
    label: [11]u8 = [_]u8{0} ** 11,

    pub fn format(self: *Fat32Volume, label: []const u8) void {
        self.bpb = .{};
        self.bpb.jmp_boot = .{ 0xEB, 0x58, 0x90 };
        self.bpb.oem_name = .{ 'Z', 'I', 'R', 'C', 'O', 'N', ' ', ' ' };
        self.bpb.bytes_per_sector = SECTOR_SIZE;
        self.bpb.sectors_per_cluster = @intCast(SECTORS_PER_CLUSTER);
        self.bpb.reserved_sectors = 32;
        self.bpb.num_fats = 2;
        self.bpb.media = 0xF8;
        self.bpb.sectors_per_track = 63;
        self.bpb.num_heads = 255;
        self.bpb.total_sectors_32 = @intCast(MAX_DATA_SECTORS + 64);
        self.bpb.fat_size_32 = @intCast(MAX_FAT_ENTRIES * 4 / SECTOR_SIZE);
        self.bpb.root_cluster = 2;
        self.bpb.fs_info = 1;
        self.bpb.backup_boot_sector = 6;
        self.bpb.drive_number = 0x80;
        self.bpb.boot_sig = 0x29;
        self.bpb.volume_id = 0x12345678;
        self.bpb.fs_type = .{ 'F', 'A', 'T', '3', '2', ' ', ' ', ' ' };

        const copy_len = @min(label.len, 11);
        @memcpy(self.label[0..copy_len], label[0..copy_len]);
        @memcpy(self.bpb.volume_label[0..copy_len], label[0..copy_len]);

        self.fat_table[0] = 0x0FFFFFF8;
        self.fat_table[1] = 0x0FFFFFFF;
        self.fat_table[2] = FAT32_EOC;

        self.next_free_cluster = 3;
        self.root_entry_count = 0;
        self.is_mounted = true;

        klog.info("FAT32: Volume formatted (label='%s')", .{label});
    }

    pub fn allocCluster(self: *Fat32Volume) ?u32 {
        if (self.next_free_cluster >= MAX_FAT_ENTRIES) return null;
        const cluster = self.next_free_cluster;
        self.fat_table[cluster] = FAT32_EOC;
        self.next_free_cluster += 1;
        return cluster;
    }

    pub fn freeCluster(self: *Fat32Volume, cluster: u32) void {
        if (cluster < 2 or cluster >= MAX_FAT_ENTRIES) return;
        self.fat_table[cluster] = FAT32_FREE;
    }

    pub fn getNextCluster(self: *const Fat32Volume, cluster: u32) ?u32 {
        if (cluster < 2 or cluster >= MAX_FAT_ENTRIES) return null;
        const next = self.fat_table[cluster] & 0x0FFFFFFF;
        if (next >= FAT32_EOC) return null;
        if (next < 2) return null;
        return next;
    }

    pub fn clusterToOffset(self: *const Fat32Volume, cluster: u32) ?usize {
        _ = self;
        if (cluster < 2) return null;
        return (cluster - 2) * CLUSTER_SIZE;
    }

    pub fn createFile(self: *Fat32Volume, name: []const u8, attr: u8) ?*DirEntry83 {
        if (self.root_entry_count >= MAX_DIR_ENTRIES) return null;

        var entry = &self.root_entries[self.root_entry_count];
        entry.* = .{};

        var i: usize = 0;
        var dot_pos: usize = name.len;
        for (name, 0..) |c, idx| {
            if (c == '.') { dot_pos = idx; break; }
        }

        while (i < 8 and i < dot_pos) : (i += 1) {
            entry.name[i] = toUpper(name[i]);
        }

        if (dot_pos < name.len) {
            var j: usize = 0;
            var k = dot_pos + 1;
            while (j < 3 and k < name.len) : ({ j += 1; k += 1; }) {
                entry.ext[j] = toUpper(name[k]);
            }
        }

        entry.attr = attr;

        if (self.allocCluster()) |cluster| {
            entry.setFirstCluster(cluster);
        }

        self.root_entry_count += 1;
        return entry;
    }

    pub fn createDirectory(self: *Fat32Volume, name: []const u8) ?*DirEntry83 {
        return self.createFile(name, ATTR_DIRECTORY);
    }

    pub fn findEntry(self: *Fat32Volume, name: []const u8) ?*DirEntry83 {
        for (self.root_entries[0..self.root_entry_count]) |*entry| {
            if (entry.isFree()) continue;
            if (matchName(entry, name)) return entry;
        }
        return null;
    }

    pub fn removeEntry(self: *Fat32Volume, name: []const u8) bool {
        for (self.root_entries[0..self.root_entry_count]) |*entry| {
            if (entry.isFree()) continue;
            if (matchName(entry, name)) {
                const cluster = entry.getFirstCluster();
                self.freeClusterChain(cluster);
                entry.name[0] = 0xE5;
                return true;
            }
        }
        return false;
    }

    fn freeClusterChain(self: *Fat32Volume, start: u32) void {
        var cluster = start;
        while (cluster >= 2 and cluster < MAX_FAT_ENTRIES) {
            const next = self.fat_table[cluster] & 0x0FFFFFFF;
            self.fat_table[cluster] = FAT32_FREE;
            if (next >= FAT32_EOC or next < 2) break;
            cluster = next;
        }
    }

    pub fn writeData(self: *Fat32Volume, cluster: u32, data: []const u8) usize {
        const offset = self.clusterToOffset(cluster) orelse return 0;
        const max_write = @min(data.len, CLUSTER_SIZE);
        if (offset + max_write > self.data_area.len) return 0;
        @memcpy(self.data_area[offset..][0..max_write], data[0..max_write]);
        return max_write;
    }

    pub fn readData(self: *const Fat32Volume, cluster: u32, buffer: []u8) usize {
        const offset = self.clusterToOffset(cluster) orelse return 0;
        const max_read = @min(buffer.len, CLUSTER_SIZE);
        if (offset + max_read > self.data_area.len) return 0;
        @memcpy(buffer[0..max_read], self.data_area[offset..][0..max_read]);
        return max_read;
    }

    pub fn getEntryCount(self: *const Fat32Volume) usize {
        return self.root_entry_count;
    }

    pub fn getFreeClusters(self: *const Fat32Volume) u32 {
        var free: u32 = 0;
        for (self.fat_table[2..]) |entry| {
            if (entry == FAT32_FREE) free += 1;
        }
        return free;
    }
};

fn matchName(entry: *const DirEntry83, name: []const u8) bool {
    var short: [12]u8 = [_]u8{' '} ** 12;
    var pos: usize = 0;
    for (entry.name) |c| {
        if (c == ' ') break;
        short[pos] = c;
        pos += 1;
    }
    var has_ext = false;
    for (entry.ext) |c| {
        if (c != ' ') { has_ext = true; break; }
    }
    if (has_ext) {
        short[pos] = '.';
        pos += 1;
        for (entry.ext) |c| {
            if (c == ' ') break;
            short[pos] = c;
            pos += 1;
        }
    }

    if (pos != name.len) return false;
    for (short[0..pos], name) |a, b| {
        if (a != toUpper(b)) return false;
    }
    return true;
}

fn toUpper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

// ── VFS Integration ──

var volume: Fat32Volume = .{};

pub fn getVolume() *Fat32Volume {
    return &volume;
}

fn fat32Open(f: *vfs.FileObject, path: []const u8, _: vfs.FileAccessMode) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;

    var name_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') name_start = i + 1;
    }
    const filename = path[name_start..];

    const entry = volume.findEntry(filename);
    if (entry) |e| {
        f.file_size = e.file_size;
        f.fs_data = e.getFirstCluster();
        if (e.isDirectory()) {
            f.file_type = .directory;
        }
        return .success;
    }
    return .not_found;
}

fn fat32Close(_: *vfs.FileObject) vfs.FileStatus {
    return .success;
}

fn fat32Read(f: *vfs.FileObject, buffer: []u8) vfs.ReadResult {
    if (!volume.is_mounted) return .{ .status = .not_mounted };

    const cluster: u32 = @intCast(f.fs_data);
    if (cluster < 2) return .{ .status = .io_error };

    const bytes = volume.readData(cluster, buffer);
    f.position += bytes;
    return .{ .status = .success, .bytes_read = bytes };
}

fn fat32Write(f: *vfs.FileObject, data: []const u8) vfs.WriteResult {
    if (!volume.is_mounted) return .{ .status = .not_mounted };

    const cluster: u32 = @intCast(f.fs_data);
    if (cluster < 2) return .{ .status = .io_error };

    const bytes = volume.writeData(cluster, data);
    f.position += bytes;
    if (f.position > f.file_size) f.file_size = f.position;
    return .{ .status = .success, .bytes_written = bytes };
}

fn fat32Readdir(_: *vfs.FileObject, entries: []vfs.DirEntry) usize {
    if (!volume.is_mounted) return 0;

    var count: usize = 0;
    for (volume.root_entries[0..volume.root_entry_count]) |*fat_entry| {
        if (count >= entries.len) break;
        if (fat_entry.isFree()) continue;
        if (fat_entry.isVolumeId()) continue;

        var e = &entries[count];
        e.* = .{};

        var pos: usize = 0;
        for (fat_entry.name) |c| {
            if (c == ' ') break;
            if (pos < e.name.len) { e.name[pos] = c; pos += 1; }
        }
        var has_ext = false;
        for (fat_entry.ext) |c| {
            if (c != ' ') { has_ext = true; break; }
        }
        if (has_ext) {
            if (pos < e.name.len) { e.name[pos] = '.'; pos += 1; }
            for (fat_entry.ext) |c| {
                if (c == ' ') break;
                if (pos < e.name.len) { e.name[pos] = c; pos += 1; }
            }
        }
        e.name_len = pos;

        e.file_size = fat_entry.file_size;
        e.file_type = if (fat_entry.isDirectory()) .directory else .regular;
        e.attributes.readonly = (fat_entry.attr & ATTR_READ_ONLY) != 0;
        e.attributes.hidden = (fat_entry.attr & ATTR_HIDDEN) != 0;
        e.attributes.system = (fat_entry.attr & ATTR_SYSTEM) != 0;
        e.attributes.directory = fat_entry.isDirectory();

        count += 1;
    }
    return count;
}

fn fat32Mkdir(path: []const u8) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    var name_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') name_start = i + 1;
    }
    if (volume.createDirectory(path[name_start..])) |_| {
        return .success;
    }
    return .disk_full;
}

fn fat32Remove(path: []const u8) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    var name_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') name_start = i + 1;
    }
    if (volume.removeEntry(path[name_start..])) {
        return .success;
    }
    return .not_found;
}

fn fat32Stat(path: []const u8, entry: *vfs.DirEntry) vfs.FileStatus {
    if (!volume.is_mounted) return .not_mounted;
    var name_start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') name_start = i + 1;
    }
    const fat_entry = volume.findEntry(path[name_start..]) orelse return .not_found;

    entry.* = .{};
    entry.file_size = fat_entry.file_size;
    entry.file_type = if (fat_entry.isDirectory()) .directory else .regular;
    entry.attributes.readonly = (fat_entry.attr & ATTR_READ_ONLY) != 0;
    entry.attributes.directory = fat_entry.isDirectory();
    return .success;
}

pub fn getOps() vfs.FsOps {
    return .{
        .open = &fat32Open,
        .close = &fat32Close,
        .read = &fat32Read,
        .write = &fat32Write,
        .readdir = &fat32Readdir,
        .mkdir = &fat32Mkdir,
        .remove = &fat32Remove,
        .stat = &fat32Stat,
    };
}

pub fn init() void {
    volume.format("ZIRCONOS");
    _ = volume.createDirectory("Windows");
    _ = volume.createDirectory("System32");
    _ = volume.createDirectory("Users");
    _ = volume.createFile("bootmgr", ATTR_SYSTEM | ATTR_HIDDEN);

    _ = vfs.mount("C:\\", .fat32, getOps(), 0, "FAT32-System");

    klog.info("FAT32: Volume initialized (free_clusters=%u)", .{volume.getFreeClusters()});
}
