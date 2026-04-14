//! Explorer 用卷快照：从 [`vfs`](vfs.zig) 枚举 DOS 挂载点与容量（替代静态 stub 表）。
//!
//! 支持：
//! - 驱动器根目录枚举
//! - 子目录枚举
//! - 文件/目录排序（按名称/大小/日期）

const std = @import("std");
const vfs = @import("vfs.zig");
const icons = @import("../desktop/kernel/icons/root.zig");

pub const ExplorerVolKind = enum(u8) {
    fixed,
    removable_block,
    optical,
};

pub const ExplorerVolume = struct {
    mount_idx: u32,
    letter: u8,
    kind: ExplorerVolKind,
    fs_type: vfs.FsType,
    label: [16]u8,
    label_len: usize,
    total_mb: u32,
    free_mb: u32,
    space_known: bool,

    pub fn iconId(self: ExplorerVolume) icons.IconId {
        return switch (self.kind) {
            .fixed => .drive_fixed,
            .removable_block => .drive_removable,
            .optical => .drive_optical,
        };
    }
};

/// 排序方式
pub const SortBy = enum(u8) {
    name,
    date,
    size,
    type_,
};

pub const ExplorerListEntry = struct {
    name: [vfs.MAX_NAME]u8,
    name_len: usize,
    date: [24]u8,
    date_len: usize,
    size: [32]u8,
    size_len: usize,
    icon: icons.IconId,
    /// 文件大小（用于排序）
    file_size: u64,
    /// 修改时间（用于排序）
    modification_time: u64,
    /// 是否为目录
    is_directory: bool,
};

/// Explorer 目录缓存条目（用于子目录导航）
pub const ExplorerDirEntry = struct {
    entry: ExplorerListEntry,
    /// VFS 文件句柄（用于进入子目录）
    dir_handle: vfs.Handle,
};

pub fn classifyFsKind(fs: vfs.FsType) ExplorerVolKind {
    return switch (fs) {
        .fat12, .fat16, .fat32, .ntfs, .exfat, .unknown => .fixed,
        .devfs => .removable_block,
        .iso9660, .udf, .refs => .removable_block,
    };
}

/// 填充 `out`，返回卷数（按 VFS 挂载顺序）。
pub fn refreshVolumes(out: []ExplorerVolume) usize {
    var infos: [vfs.MAX_MOUNT_POINTS]vfs.MountInfo = undefined;
    const n = vfs.copyDosDriveMountInfos(infos[0..]);
    var o: usize = 0;
    for (0..n) |i| {
        if (o >= out.len) break;
        const mi = infos[i];
        var total: u64 = 0;
        var free: u64 = 0;
        const st = vfs.queryMountSpace(mi.mount_idx, &total, &free);
        const known = (st == .success);
        var total_mb: u32 = 0;
        var free_mb: u32 = 0;
        if (known) {
            total_mb = @intCast(@min(total / (1024 * 1024), @as(u64, 0xFFFF_FFFF)));
            free_mb = @intCast(@min(free / (1024 * 1024), @as(u64, 0xFFFF_FFFF)));
        }
        var lab: [16]u8 = [_]u8{0} ** 16;
        const lab_len = @min(mi.label.len, lab.len);
        @memcpy(lab[0..lab_len], mi.label[0..lab_len]);
        out[o] = .{
            .mount_idx = mi.mount_idx,
            .letter = mi.drive_letter,
            .kind = classifyFsKind(mi.fs_type),
            .fs_type = mi.fs_type,
            .label = lab,
            .label_len = lab_len,
            .total_mb = total_mb,
            .free_mb = free_mb,
            .space_known = known,
        };
        o += 1;
    }
    return o;
}

pub fn volumeByLetter(vols: []const ExplorerVolume, letter: u8) ?ExplorerVolume {
    const L = if (letter >= 'a' and letter <= 'z') letter - 32 else letter;
    for (vols) |v| {
        if (v.letter == L) return v;
    }
    return null;
}

pub fn formatDriveRootPath(buf: []u8, letter: u8) []const u8 {
    var L = letter;
    if (L >= 'a' and L <= 'z') L -= 32;
    return std.fmt.bufPrint(buf, "{c}:\\", .{L}) catch "C:\\";
}

/// 格式化完整路径（包括子目录）
pub fn formatFullPath(buf: []u8, letter: u8, subpath: ?[]const u8) []const u8 {
    var L = letter;
    if (L >= 'a' and L <= 'z') L -= 32;
    if (subpath) |sp| {
        return std.fmt.bufPrint(buf, "{c}:\\{s}", .{ L, sp }) catch formatDriveRootPath(buf, letter);
    }
    return formatDriveRootPath(buf, letter);
}

fn formatListDate(buf: []u8, mod_t: u64) []const u8 {
    if (mod_t == 0) {
        const dash = "--";
        if (buf.len >= dash.len) {
            @memcpy(buf[0..dash.len], dash);
            return buf[0..dash.len];
        }
        return "--";
    }
    return std.fmt.bufPrint(buf, "{d}", .{mod_t}) catch "--";
}

fn formatListSize(buf: []u8, is_dir: bool, sz: u64) []const u8 {
    if (is_dir) return buf[0..0];
    if (sz < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{sz}) catch "";
    }
    if (sz < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d} KB", .{@divTrunc(sz, 1024)}) catch "";
    }
    return std.fmt.bufPrint(buf, "{d} MB", .{@divTrunc(sz, 1024 * 1024)}) catch "";
}

/// 格式化条目大小（供外部调用）
pub fn formatEntrySize(buf: []u8, is_dir: bool, sz: u64) []const u8 {
    return formatListSize(buf, is_dir, sz);
}

/// 比较函数用于排序
fn compareEntries(a: *const ExplorerListEntry, b: *const ExplorerListEntry, sort_by: SortBy, ascending: bool) bool {
    // 目录优先于文件
    if (a.is_directory != b.is_directory) {
        return ascending;
    }

    const cmp_result: std.math.Order = switch (sort_by) {
        .name => std.ascii.orderIgnoreCase(a.name[0..a.name_len], b.name[0..b.name_len]),
        .date => @as(std.math.Order, if (a.modification_time < b.modification_time) .lt else if (a.modification_time > b.modification_time) .gt else .eq),
        .size => @as(std.math.Order, if (a.file_size < b.file_size) .lt else if (a.file_size > b.file_size) .gt else .eq),
        .type_ => std.ascii.orderIgnoreCase(getFileExtension(a), getFileExtension(b)),
    };

    return switch (cmp_result) {
        .lt => ascending,
        .gt => !ascending,
        .eq => false,
    };
}

fn getFileExtension(entry: *const ExplorerListEntry) []const u8 {
    if (entry.is_directory) return "";
    var dot_pos: usize = 0;
    for (entry.name[0..entry.name_len], 0..) |c, i| {
        if (c == '.') dot_pos = i + 1;
    }
    if (dot_pos == 0 or dot_pos >= entry.name_len) return "";
    return entry.name[dot_pos..entry.name_len];
}

/// 简单冒泡排序（用于少量条目）
fn sortEntries(entries: []ExplorerListEntry, sort_by: SortBy, ascending: bool) void {
    if (entries.len <= 1) return;
    var i: usize = 0;
    while (i < entries.len - 1) : (i += 1) {
        var j: usize = 0;
        while (j < entries.len - 1 - i) : (j += 1) {
            if (compareEntries(&entries[j], &entries[j + 1], sort_by, ascending)) {
                const temp = entries[j];
                entries[j] = entries[j + 1];
                entries[j + 1] = temp;
            }
        }
    }
}

/// 枚举 `X:\` 根目录（需 `open` 根路径成功）。
pub fn readDriveRootList(letter: u8, out: []ExplorerListEntry) usize {
    return readDirectoryGeneric(letter, null, out, .name, true);
}

/// 枚举子目录
pub fn readSubdirectoryList(letter: u8, subpath: []const u8, out: []ExplorerListEntry) usize {
    return readDirectoryGeneric(letter, subpath, out, .name, true);
}

/// 通用目录枚举函数
pub fn readDirectoryGeneric(
    letter: u8,
    subpath: ?[]const u8,
    out: []ExplorerListEntry,
    sort_by: SortBy,
    ascending: bool,
) usize {
    var path_buf: [256]u8 = undefined;
    const full_path = formatFullPath(&path_buf, letter, subpath);

    const h = vfs.open(full_path, .read) orelse return 0;
    defer _ = vfs.close(h);
    if (h.file_type != .directory) return 0;

    var vfs_entries: [64]vfs.DirEntry = undefined;
    const n = vfs.readdir(h, vfs_entries[0..]);
    var o: usize = 0;
    var i: usize = 0;
    while (i < n and o < out.len) : (i += 1) {
        const e = vfs_entries[i];
        if (e.name_len == 0) continue;

        // 跳过隐藏文件（以 . 开头）
        if (e.name[0] == '.') continue;

        var row = &out[o];
        row.* = .{
            .name = undefined,
            .name_len = @min(e.name_len, row.name.len),
            .date = undefined,
            .date_len = 0,
            .size = undefined,
            .size_len = 0,
            .icon = if (e.file_type == .directory) .folder else .file,
            .file_size = e.file_size,
            .modification_time = e.modification_time,
            .is_directory = e.file_type == .directory,
        };
        @memcpy(row.name[0..row.name_len], e.name[0..row.name_len]);
        const ds = formatListDate(row.date[0..], e.modification_time);
        row.date_len = ds.len;
        @memcpy(row.date[0..row.date_len], ds);
        const ss = formatListSize(row.size[0..], e.file_type == .directory, e.file_size);
        row.size_len = ss.len;
        @memcpy(row.size[0..row.size_len], ss);
        o += 1;
    }

    // 排序
    sortEntries(out[0..o], sort_by, ascending);

    return o;
}

/// 打开子目录并返回句柄（用于进入子目录）
pub fn openSubdirectory(letter: u8, subpath: []const u8) ?vfs.Handle {
    var path_buf: [256]u8 = undefined;
    const full_path = formatFullPath(&path_buf, letter, subpath);
    return vfs.open(full_path, .read);
}

/// 获取条目的完整路径
pub fn getEntryFullPath(buf: []u8, letter: u8, subpath: ?[]const u8, entry_name: []const u8) []const u8 {
    var path_buf: [256]u8 = undefined;
    const base_path = formatFullPath(&path_buf, letter, subpath);
    return std.fmt.bufPrint(buf, "{s}\\{s}", .{ base_path, entry_name }) catch "";
}
