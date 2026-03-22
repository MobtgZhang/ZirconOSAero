//! Virtual File System (VFS) - NT style
//! Provides a unified file system interface and dispatches to registered FS drivers.
//! Manages mount points, file objects, and directory enumeration.

const ob = @import("../ob/object.zig");
const klog = @import("../rtl/klog.zig");

pub const MAX_PATH: usize = 260;
pub const MAX_NAME: usize = 128;

pub const FileAccessMode = enum(u32) {
    read = 0x80000000,
    write = 0x40000000,
    read_write = 0xC0000000,
    execute = 0x20000000,
};

pub const FileAttributes = packed struct(u32) {
    readonly: bool = false,
    hidden: bool = false,
    system: bool = false,
    _pad1: bool = false,
    directory: bool = false,
    archive: bool = false,
    _reserved: u26 = 0,
};

pub const FileType = enum(u8) {
    regular = 0,
    directory = 1,
    device = 2,
    symbolic_link = 3,
    pipe = 4,
};

pub const SeekOrigin = enum(u8) {
    begin = 0,
    current = 1,
    end = 2,
};

pub const DirEntry = struct {
    name: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: usize = 0,
    file_type: FileType = .regular,
    file_size: u64 = 0,
    attributes: FileAttributes = .{},
    creation_time: u64 = 0,
    modification_time: u64 = 0,
};

pub const FileStatus = enum(u32) {
    success = 0,
    not_found = 1,
    access_denied = 2,
    already_exists = 3,
    disk_full = 4,
    not_directory = 5,
    is_directory = 6,
    io_error = 7,
    invalid_parameter = 8,
    not_implemented = 9,
    end_of_file = 10,
    buffer_too_small = 11,
    not_mounted = 12,
};

pub const FsType = enum(u8) {
    unknown = 0,
    fat32 = 1,
    ntfs = 2,
    devfs = 3,
};

pub const MAX_OPEN_FILES: usize = 128;
pub const MAX_MOUNT_POINTS: usize = 16;

pub const FsOps = struct {
    open: ?*const fn (*FileObject, []const u8, FileAccessMode) FileStatus = null,
    close: ?*const fn (*FileObject) FileStatus = null,
    read: ?*const fn (*FileObject, []u8) ReadResult = null,
    write: ?*const fn (*FileObject, []const u8) WriteResult = null,
    readdir: ?*const fn (*FileObject, []DirEntry) usize = null,
    mkdir: ?*const fn ([]const u8) FileStatus = null,
    remove: ?*const fn ([]const u8) FileStatus = null,
    stat: ?*const fn ([]const u8, *DirEntry) FileStatus = null,
    seek: ?*const fn (*FileObject, i64, SeekOrigin) FileStatus = null,
};

pub const ReadResult = struct {
    status: FileStatus = .success,
    bytes_read: usize = 0,
};

pub const WriteResult = struct {
    status: FileStatus = .success,
    bytes_written: usize = 0,
};

pub const FileObject = struct {
    header: ob.ObjectHeader = .{ .obj_type = .file },
    path: [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    path_len: usize = 0,
    file_type: FileType = .regular,
    access_mode: FileAccessMode = .read,
    position: u64 = 0,
    file_size: u64 = 0,
    mount_idx: u32 = 0,
    is_open: bool = false,
    fs_data: u64 = 0,
};

pub const MountPoint = struct {
    prefix: [32]u8 = [_]u8{0} ** 32,
    prefix_len: usize = 0,
    fs_type: FsType = .unknown,
    ops: FsOps = .{},
    device_idx: u32 = 0,
    is_active: bool = false,
    label: [16]u8 = [_]u8{0} ** 16,
    label_len: usize = 0,
};

var files: [MAX_OPEN_FILES]FileObject = [_]FileObject{.{}} ** MAX_OPEN_FILES;
var file_count: usize = 0;

var mounts: [MAX_MOUNT_POINTS]MountPoint = [_]MountPoint{.{}} ** MAX_MOUNT_POINTS;
var mount_count: usize = 0;

var vfs_initialized: bool = false;

pub fn init() void {
    file_count = 0;
    mount_count = 0;
    vfs_initialized = true;

    _ = ob.insertNamespace("\\FileSystem", .directory, 0, 0);
    _ = ob.insertNamespace("\\DosDevices", .directory, 0, 0);

    klog.info("VFS: Virtual File System initialized", .{});
}

pub fn mount(prefix: []const u8, fs_type: FsType, ops: FsOps, device_idx: u32, label: []const u8) FileStatus {
    if (mount_count >= MAX_MOUNT_POINTS) return .disk_full;

    var mp = &mounts[mount_count];
    mp.* = .{};
    const prefix_copy = @min(prefix.len, mp.prefix.len);
    @memcpy(mp.prefix[0..prefix_copy], prefix[0..prefix_copy]);
    mp.prefix_len = prefix_copy;
    mp.fs_type = fs_type;
    mp.ops = ops;
    mp.device_idx = device_idx;
    mp.is_active = true;

    const label_copy = @min(label.len, mp.label.len);
    @memcpy(mp.label[0..label_copy], label[0..label_copy]);
    mp.label_len = label_copy;

    mount_count += 1;

    klog.info("VFS: Mounted '%s' as %s (device=%u)", .{ prefix, label, device_idx });
    return .success;
}

pub fn unmount(prefix: []const u8) FileStatus {
    for (mounts[0..mount_count]) |*mp| {
        if (!mp.is_active) continue;
        if (mp.prefix_len == prefix.len) {
            var match = true;
            for (mp.prefix[0..mp.prefix_len], prefix) |a, b| {
                if (a != b) {
                    match = false;
                    break;
                }
            }
            if (match) {
                mp.is_active = false;
                klog.info("VFS: Unmounted '%s'", .{prefix});
                return .success;
            }
        }
    }
    return .not_mounted;
}

fn findMount(path: []const u8) ?*MountPoint {
    var best: ?*MountPoint = null;
    var best_len: usize = 0;
    for (mounts[0..mount_count]) |*mp| {
        if (!mp.is_active) continue;
        if (path.len >= mp.prefix_len and mp.prefix_len > best_len) {
            var match = true;
            for (mp.prefix[0..mp.prefix_len], path[0..mp.prefix_len]) |a, b| {
                if (a != b) {
                    match = false;
                    break;
                }
            }
            if (match) {
                best = mp;
                best_len = mp.prefix_len;
            }
        }
    }
    return best;
}

pub fn open(path: []const u8, access: FileAccessMode) ?*FileObject {
    if (file_count >= MAX_OPEN_FILES) return null;

    const mp = findMount(path) orelse return null;

    var f = &files[file_count];
    f.* = .{};
    const copy_len = @min(path.len, f.path.len);
    @memcpy(f.path[0..copy_len], path[0..copy_len]);
    f.path_len = copy_len;
    f.access_mode = access;
    f.mount_idx = @intCast(getMountIndex(mp));
    f.is_open = true;

    if (mp.ops.open) |open_fn| {
        const status = open_fn(f, path, access);
        if (status != .success) {
            f.is_open = false;
            return null;
        }
    }

    file_count += 1;
    return f;
}

pub fn close(f: *FileObject) FileStatus {
    if (!f.is_open) return .invalid_parameter;

    if (f.mount_idx < mount_count) {
        const mp = &mounts[f.mount_idx];
        if (mp.ops.close) |close_fn| {
            _ = close_fn(f);
        }
    }

    f.is_open = false;
    return .success;
}

pub fn read(f: *FileObject, buffer: []u8) ReadResult {
    if (!f.is_open) return .{ .status = .invalid_parameter };

    if (f.mount_idx < mount_count) {
        const mp = &mounts[f.mount_idx];
        if (mp.ops.read) |read_fn| {
            return read_fn(f, buffer);
        }
    }
    return .{ .status = .not_implemented };
}

pub fn write(f: *FileObject, data: []const u8) WriteResult {
    if (!f.is_open) return .{ .status = .invalid_parameter };

    if (f.mount_idx < mount_count) {
        const mp = &mounts[f.mount_idx];
        if (mp.ops.write) |write_fn| {
            return write_fn(f, data);
        }
    }
    return .{ .status = .not_implemented };
}

pub fn readdir(f: *FileObject, entries: []DirEntry) usize {
    if (!f.is_open) return 0;
    if (f.mount_idx < mount_count) {
        const mp = &mounts[f.mount_idx];
        if (mp.ops.readdir) |readdir_fn| {
            return readdir_fn(f, entries);
        }
    }
    return 0;
}

pub fn stat(path: []const u8, entry: *DirEntry) FileStatus {
    const mp = findMount(path) orelse return .not_mounted;
    if (mp.ops.stat) |stat_fn| {
        return stat_fn(path, entry);
    }
    return .not_implemented;
}

fn getMountIndex(mp: *MountPoint) usize {
    const base = @intFromPtr(&mounts[0]);
    const ptr = @intFromPtr(mp);
    return (ptr - base) / @sizeOf(MountPoint);
}

pub fn getMountCount() usize {
    return mount_count;
}

pub fn getFileCount() usize {
    return file_count;
}

pub fn isInitialized() bool {
    return vfs_initialized;
}
