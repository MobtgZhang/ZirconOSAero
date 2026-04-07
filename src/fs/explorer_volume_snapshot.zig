//! Explorer 用卷快照：从 [`vfs`](vfs.zig) 枚举 DOS 挂载点与容量（替代静态 stub 表）。

const std = @import("std");
const vfs = @import("vfs.zig");
const icons = @import("../drivers/video/desktop/icons.zig");

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

pub const ExplorerListEntry = struct {
    name: [vfs.MAX_NAME]u8,
    name_len: usize,
    date: [24]u8,
    date_len: usize,
    size: [32]u8,
    size_len: usize,
    icon: icons.IconId,
};

pub fn classifyFsKind(fs: vfs.FsType) ExplorerVolKind {
    return switch (fs) {
        .fat32, .ntfs, .unknown => .fixed,
        .devfs => .removable_block,
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

/// 枚举 `X:\` 根目录（需 `open` 根路径成功）。
pub fn readDriveRootList(letter: u8, out: []ExplorerListEntry) usize {
    var path_buf: [8]u8 = undefined;
    const root = formatDriveRootPath(&path_buf, letter);
    const h = vfs.open(root, .read) orelse return 0;
    defer _ = vfs.close(h);
    if (h.file_type != .directory) return 0;

    var vfs_entries: [64]vfs.DirEntry = undefined;
    const n = vfs.readdir(h, vfs_entries[0..]);
    var o: usize = 0;
    var i: usize = 0;
    while (i < n and o < out.len) : (i += 1) {
        const e = vfs_entries[i];
        if (e.name_len == 0) continue;
        var row = &out[o];
        row.* = .{
            .name = undefined,
            .name_len = @min(e.name_len, row.name.len),
            .date = undefined,
            .date_len = 0,
            .size = undefined,
            .size_len = 0,
            .icon = if (e.file_type == .directory) .folder else .file,
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
    return o;
}
