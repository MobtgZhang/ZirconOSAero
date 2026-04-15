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
// Module: src/fs/vfs.zig
// Purpose: 虚拟文件系统挂载、`FileObject`、经卷设备对象的 IRP 分发与 `NTSTATUS` 映射。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/ — I/O stack, IRP;
//      Phase K8 / K4 见 docs/cn/NT61_KERNEL_TODO.md。

const std = @import("std");
const ob = @import("../ob/object.zig");
const io = @import("../io/io.zig");
const klog = @import("../rtl/klog.zig");
const token = @import("../se/token.zig");
const se = @import("../se/security_descriptor.zig");

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
    initfs = 1,
    fat12 = 2,
    fat16 = 3,
    fat32 = 4,
    ntfs = 5,
    exfat = 6,
    devfs = 7,
    iso9660 = 8,
    udf = 9,
    refs = 10,
};

pub const MAX_OPEN_FILES: usize = 128;
pub const MAX_MOUNT_POINTS: usize = 16;

/// VFS 文件句柄（等同于 `*FileObject`）
pub const Handle = *FileObject;

pub const FsOps = struct {
    open: ?*const fn (*FileObject, []const u8, FileAccessMode) FileStatus = null,
    /// 最后一道句柄关闭时的驱动收尾（等价 **IRP_MJ_CLEANUP** 子集）；在 `close` 之前调用。
    cleanup: ?*const fn (*FileObject) FileStatus = null,
    close: ?*const fn (*FileObject) FileStatus = null,
    read: ?*const fn (*FileObject, []u8) ReadResult = null,
    write: ?*const fn (*FileObject, []const u8) WriteResult = null,
    readdir: ?*const fn (*FileObject, []DirEntry) usize = null,
    mkdir: ?*const fn ([]const u8) FileStatus = null,
    remove: ?*const fn ([]const u8) FileStatus = null,
    stat: ?*const fn ([]const u8, *DirEntry) FileStatus = null,
    seek: ?*const fn (*FileObject, i64, SeekOrigin) FileStatus = null,
    /// 卷总/可用字节（Explorer / DiskPart）；未实现则返回 `.not_implemented`。
    query_space: ?*const fn (mount_idx: u32, *u64, *u64) FileStatus = null,
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
    /// `FILE_SHARE_*` 子集（与 `ntdll` 打开路径对齐）。
    share_access: u32 = 0,
    /// `NtQueryDirectoryFile` 游标（仅目录句柄）。
    dir_enum_next: u32 = 0,
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
    /// 卷设备栈顶索引（`io.createDevice`）；0 表示未创建（回退直接 `FsOps`）。
    volume_device_idx: u32 = 0,
};

var files: [MAX_OPEN_FILES]FileObject = [_]FileObject{.{}} ** MAX_OPEN_FILES;
var file_count: usize = 0;

var mounts: [MAX_MOUNT_POINTS]MountPoint = [_]MountPoint{.{}} ** MAX_MOUNT_POINTS;
var mount_count: usize = 0;

var vfs_initialized: bool = false;
var vfs_volume_driver_idx: u32 = 0;
var vfs_volume_driver_ready: bool = false;

const VolumeDeviceExtension = extern struct {
    mount_idx: u32 align(1) = 0,
};

fn volumeDeviceName(mount_idx: usize, out: *[32]u8) []const u8 {
    const lit = "\\Device\\VFS";
    var len: usize = lit.len;
    @memcpy(out[0..len], lit);
    var n = mount_idx;
    var rev: [12]u8 = undefined;
    var r: usize = 0;
    if (n == 0) {
        rev[r] = '0';
        r += 1;
    } else {
        while (n > 0) : (n /= 10) {
            rev[r] = @as(u8, @intCast((n % 10) + '0'));
            r += 1;
        }
    }
    while (r > 0) {
        r -= 1;
        out[len] = rev[r];
        len += 1;
    }
    return out[0..len];
}

/// `C:\` / `D:/` 等 DOS 盘符路径 → 大写字母；否则 `null`。
pub fn driveLetterFromDosPath(prefix: []const u8) ?u8 {
    if (prefix.len < 2) return null;
    var c0 = prefix[0];
    if (!((c0 >= 'A' and c0 <= 'Z') or (c0 >= 'a' and c0 <= 'z'))) return null;
    if (prefix[1] != ':') return null;
    if (prefix.len > 2 and prefix[2] != '\\' and prefix[2] != '/') return null;
    if (c0 >= 'a') c0 = c0 - 32;
    return c0;
}

fn registerDosDriveSymlink(letter: u8, dev: *io.DeviceObject) void {
    var name: [24]u8 = undefined;
    const p1 = "\\DosDevices\\";
    @memcpy(name[0..p1.len], p1);
    name[p1.len] = letter;
    name[p1.len + 1] = ':';
    const total = p1.len + 2;
    _ = ob.insertNamespace(name[0..total], .symbolic_link, @intFromPtr(dev), 0);
}

fn ensureVfsVolumeDriver() void {
    if (vfs_volume_driver_ready) return;
    vfs_volume_driver_idx = io.registerDriver("\\Driver\\VfsVolume", vfsVolumeDispatch) orelse {
        klog.warn("VFS: registerDriver VfsVolume failed", .{});
        return;
    };
    vfs_volume_driver_ready = true;
}

fn vfsVolumePnpDispatch(irp: *io.Irp) io.NTSTATUS {
    switch (irp.minor_function) {
        0 => {
            klog.debug("VFS: PnP IRP_MN_START_DEVICE (volume)", .{});
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        7 => {
            klog.debug("VFS: PnP IRP_MN_QUERY_CAPABILITIES (volume stub)", .{});
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        2 => {
            klog.debug("VFS: PnP IRP_MN_REMOVE_DEVICE (volume stub)", .{});
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        else => {
            irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
            return io.STATUS_NOT_IMPLEMENTED;
        },
    }
}

fn vfsVolumePowerDispatch(irp: *io.Irp) io.NTSTATUS {
    klog.debug("VFS: POWER minor=%u (stub)", .{irp.minor_function});
    irp.complete(io.STATUS_SUCCESS, 0);
    return io.STATUS_SUCCESS;
}

fn vfsVolumeDispatch(irp: *io.Irp) io.NTSTATUS {
    const dev: *io.DeviceObject = @ptrFromInt(irp.device_ptr);
    const ext: *align(1) VolumeDeviceExtension = @ptrCast(io.IoGetDeviceExtension(dev));
    const mp_idx: usize = @intCast(ext.mount_idx);
    if (mp_idx >= mount_count) return io.STATUS_INVALID_DEVICE_REQUEST;

    switch (irp.major_function) {
        .pnp => return vfsVolumePnpDispatch(irp),
        .power => return vfsVolumePowerDispatch(irp),
        else => {
            const file: *FileObject = if (irp.tail != 0)
                @ptrFromInt(irp.tail)
            else {
                irp.complete(io.STATUS_INVALID_PARAMETER, 0);
                return io.STATUS_INVALID_PARAMETER;
            };
            return dispatchFileObjectIrpDirect(file, irp);
        },
    }
}

/// `FileStatus` → `NTSTATUS`（与 `ntdll` / MVT 单测一致；公开供文档交叉引用）。
pub fn fileStatusToNtStatus(s: FileStatus) io.NTSTATUS {
    return switch (s) {
        .success => io.STATUS_SUCCESS,
        .not_found => io.STATUS_OBJECT_NAME_NOT_FOUND,
        .access_denied => io.STATUS_ACCESS_DENIED,
        .already_exists => io.STATUS_OBJECT_NAME_COLLISION,
        .disk_full => io.STATUS_DISK_FULL,
        .not_directory => io.STATUS_NOT_A_DIRECTORY,
        .is_directory => io.STATUS_FILE_IS_A_DIRECTORY,
        .io_error => io.STATUS_IO_DEVICE_ERROR,
        .invalid_parameter => io.STATUS_INVALID_PARAMETER,
        .not_implemented => io.STATUS_NOT_IMPLEMENTED,
        .end_of_file => io.STATUS_END_OF_FILE,
        .buffer_too_small => io.STATUS_BUFFER_TOO_SMALL,
        .not_mounted => io.STATUS_DEVICE_NOT_READY,
    };
}

/// `FILE_SHARE_*` 子集：与同路径已打开句柄的 **访问 + 共享掩码** 做相容性检测（K8.2；完整 NT 共享语义见 Learn `CreateFile`）。
fn shareConflict(path: []const u8, want_write: bool, new_share: u32) bool {
    const shr_read: u32 = 0x00000001;
    const shr_write: u32 = 0x00000002;
    for (files[0..file_count]) |*f| {
        if (!f.is_open) continue;
        if (f.path_len != path.len) continue;
        if (!std.mem.eql(u8, f.path[0..f.path_len], path)) continue;

        const ex_write = f.access_mode == .write or f.access_mode == .read_write;
        const ex_read = f.access_mode == .read or f.access_mode == .read_write;

        if (want_write) {
            if (ex_write and (f.share_access & shr_write) == 0) return true;
            if (ex_read and !ex_write and (f.share_access & shr_write) == 0) return true;
            if (ex_write and (new_share & shr_write) == 0) return true;
        } else {
            if (ex_write and (f.share_access & shr_read) == 0) return true;
            if (ex_write and (new_share & shr_read) == 0) return true;
        }
    }
    return false;
}

pub fn init() void {
    file_count = 0;
    mount_count = 0;
    vfs_initialized = true;
    vfs_volume_driver_ready = false;
    vfs_volume_driver_idx = 0;

    _ = ob.insertNamespace("\\FileSystem", .directory, 0, 0);
    _ = ob.insertNamespace("\\DosDevices", .directory, 0, 0);

    ensureVfsVolumeDriver();

    klog.info("VFS: Virtual File System initialized", .{});
}

pub fn mount(prefix: []const u8, fs_type: FsType, ops: FsOps, device_idx: u32, label: []const u8) FileStatus {
    if (mount_count >= MAX_MOUNT_POINTS) return .disk_full;

    const idx_this = mount_count;
    var mp = &mounts[idx_this];
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

    if (vfs_volume_driver_ready) {
        var nm: [32]u8 = undefined;
        const dev_name = volumeDeviceName(idx_this, &nm);
        if (io.createDevice(dev_name, .filesystem, vfs_volume_driver_idx)) |didx| {
            mp.volume_device_idx = didx;
            if (io.getDeviceObject(didx)) |dobj| {
                const ext: *align(1) VolumeDeviceExtension = @ptrCast(io.IoGetDeviceExtension(dobj));
                ext.* = .{ .mount_idx = @intCast(idx_this) };
                if (driveLetterFromDosPath(prefix)) |letter| {
                    registerDosDriveSymlink(letter, dobj);
                }
            }
        }
    }

    klog.info("VFS: Mounted '%s' as %s (device=%u vol_dev=%u)", .{
        prefix, label, device_idx, mp.volume_device_idx,
    });
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
                mp.volume_device_idx = 0;
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

pub fn resolvePath(path: []const u8) []const u8 {
    return ob.normalizeNtObjectPath(path);
}

/// 检查文件访问权限
fn checkFileAccess(path: []const u8, access: FileAccessMode, user_token: *const token.Token) bool {
    const desired_access: ob.ACCESS_MASK = switch (access) {
        .read => ob.GENERIC_READ,
        .write => ob.GENERIC_WRITE,
        .read_write => ob.GENERIC_READ | ob.GENERIC_WRITE,
        .execute => ob.GENERIC_EXECUTE,
    };

    return ob.obOpenObjectByNameAccessProbe(path, desired_access, user_token);
}

pub fn openEx(path: []const u8, access: FileAccessMode, share_access: u32) ?*FileObject {
    if (file_count >= MAX_OPEN_FILES) return null;

    const norm = resolvePath(path);
    const mp = findMount(norm) orelse return null;

    // 安全检查：验证当前用户是否有权限访问该文件
    const current_token = token.getCurrentToken();
    if (!checkFileAccess(norm, access, current_token)) {
        klog.debug("VFS: Access denied for path '%s' (access mode=%u)", .{ norm, @intFromEnum(access) });
        return null;
    }

    const want_write = access == .write or access == .read_write;
    if (shareConflict(norm, want_write, share_access)) return null;

    var f = &files[file_count];
    f.* = .{};
    const copy_len = @min(norm.len, f.path.len);
    @memcpy(f.path[0..copy_len], norm[0..copy_len]);
    f.path_len = copy_len;
    f.access_mode = access;
    f.mount_idx = @intCast(getMountIndex(mp));
    f.is_open = true;
    f.share_access = share_access;

    if (mp.ops.open) |open_fn| {
        const status = open_fn(f, norm, access);
        if (status != .success) {
            f.is_open = false;
            return null;
        }
    }

    f.dir_enum_next = 0;
    file_count += 1;
    return f;
}

pub fn open(path: []const u8, access: FileAccessMode) ?*FileObject {
    const FILE_SHARE_READ: u32 = 0x00000001;
    const FILE_SHARE_WRITE: u32 = 0x00000002;
    const FILE_SHARE_DELETE: u32 = 0x00000004;
    return openEx(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
}

pub fn close(f: *FileObject) FileStatus {
    if (!f.is_open) return .invalid_parameter;

    if (f.mount_idx < mount_count) {
        const mp = &mounts[f.mount_idx];
        if (mp.ops.cleanup) |cleanup_fn| {
            _ = cleanup_fn(f);
        }
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
    const norm = resolvePath(path);
    const mp = findMount(norm) orelse return .not_mounted;
    if (mp.ops.stat) |stat_fn| {
        return stat_fn(norm, entry);
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

/// 活跃挂载点中 **带盘符** 的项（`X:\`），供 Explorer / DiskPart 枚举。
pub const MountInfo = struct {
    mount_idx: u32,
    drive_letter: u8,
    fs_type: FsType,
    /// 生命周期：直至该挂载被 `unmount` 改写；勿跨帧长期保存指针（可每帧快照）。
    label: []const u8,
    prefix: []const u8,
};

/// 将 DOS 卷写入 `out`，返回写入条数（至多 `out.len`）。
pub fn copyDosDriveMountInfos(out: []MountInfo) usize {
    var n: usize = 0;
    for (mounts[0..mount_count], 0..) |*mp, i| {
        if (!mp.is_active) continue;
        const prefix = mp.prefix[0..mp.prefix_len];
        const letter = driveLetterFromDosPath(prefix) orelse continue;
        if (n >= out.len) break;
        out[n] = .{
            .mount_idx = @intCast(i),
            .drive_letter = letter,
            .fs_type = mp.fs_type,
            .label = mp.label[0..mp.label_len],
            .prefix = prefix,
        };
        n += 1;
    }
    return n;
}

/// `total_bytes` / `free_bytes`：卷容量与可用空间；无回调时 `.not_implemented`。
pub fn queryMountSpace(mount_idx: usize, total_bytes: *u64, free_bytes: *u64) FileStatus {
    if (mount_idx >= mount_count) return .invalid_parameter;
    const mp = &mounts[mount_idx];
    if (!mp.is_active) return .not_mounted;
    if (mp.ops.query_space) |q| {
        return q(@intCast(mount_idx), total_bytes, free_bytes);
    }
    return .not_implemented;
}

pub fn getFileCount() usize {
    return file_count;
}

pub fn isInitialized() bool {
    return vfs_initialized;
}

fn dispatchFileObjectIrpDirect(file: *FileObject, irp: *io.Irp) io.NTSTATUS {
    irp.syncSystemBuffer();
    switch (irp.major_function) {
        .read => {
            if (irp.buffer_ptr == 0 or irp.buffer_size == 0) {
                io.IoCompleteRequest(irp, io.STATUS_INVALID_PARAMETER, 0);
                return irp.status;
            }
            const buf: [*]u8 = @ptrFromInt(irp.buffer_ptr);
            const rr = read(file, buf[0..irp.buffer_size]);
            const st = fileStatusToNtStatus(rr.status);
            io.IoCompleteRequest(irp, st, rr.bytes_read);
            return irp.status;
        },
        .write => {
            if (irp.buffer_ptr == 0) {
                io.IoCompleteRequest(irp, io.STATUS_INVALID_PARAMETER, 0);
                return irp.status;
            }
            const buf: [*]const u8 = @ptrFromInt(irp.buffer_ptr);
            const wr = write(file, buf[0..irp.buffer_size]);
            const st = fileStatusToNtStatus(wr.status);
            io.IoCompleteRequest(irp, st, wr.bytes_written);
            return irp.status;
        },
        .close => {
            _ = close(file);
            io.IoCompleteRequest(irp, io.STATUS_SUCCESS, 0);
            return irp.status;
        },
        else => {
            io.IoCompleteRequest(irp, io.STATUS_NOT_IMPLEMENTED, 0);
            return irp.status;
        },
    }
}

/// 经卷设备栈（若已创建）下传，否则直接 `FsOps`。
pub fn dispatchFileObjectIrp(file: *FileObject, irp: *io.Irp) io.NTSTATUS {
    irp.tail = @intFromPtr(file);
    irp.syncSystemBuffer();
    if (file.mount_idx < mount_count) {
        const mp = &mounts[file.mount_idx];
        if (mp.volume_device_idx != 0) {
            return io.dispatchIrpThroughStack(mp.volume_device_idx, irp);
        }
    }
    return dispatchFileObjectIrpDirect(file, irp);
}
