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
// Module: src/fs/initfs.zig
// Purpose: InitFS - Initial RAM-based File System providing Windows directory structure
//
// This is a clean-room implementation providing the C:\ drive structure.

const std = @import("std");
const vfs = @import("vfs.zig");
const klog = @import("../rtl/klog.zig");
const io = @import("../io/io.zig");

pub const MAX_INITFS_ENTRIES = 512;
pub const MAX_INITFS_FILES = 256;
pub const INITFS_RAM_SIZE = 512 * 1024; // 512KB RAM disk

// ── In-Memory File Entry ──────────────────────────────────────────────────────

pub const InitFSFile = struct {
    name: [64]u8,
    name_len: usize,
    data: []const u8,
    is_directory: bool,
    is_system: bool,
    is_hidden: bool,
    is_readonly: bool,
    is_archive: bool,
    parent_index: usize,
    children_start: usize,
    children_count: usize,
    creation_time: u64,
    modification_time: u64,
};

pub const InitFSDirEntry = struct {
    name: [64]u8,
    name_len: usize,
    is_directory: bool,
    is_system: bool,
    is_hidden: bool,
    is_readonly: bool,
    is_archive: bool,
    file_size: u64,
    creation_time: u64,
    modification_time: u64,
};

// ── InitFS Directory Tree ─────────────────────────────────────────────────────

const INITFS_ROOT_PARENT: usize = 0xFFFF;

var initfs_initialized: bool = false;
var initfs_entries: [MAX_INITFS_ENTRIES]InitFSFile = undefined;
var initfs_entry_count: usize = 0;
var initfs_mounted: bool = false;
var initfs_mount_letter: u8 = 0;
var initfs_mount_idx: u32 = 0;

// Open file handles for InitFS
const MAX_INITFS_HANDLES = 32;
var initfs_handles: [MAX_INITFS_HANDLES]InitFSHandle = undefined;
var initfs_handle_count: usize = 0;

pub const InitFSHandle = struct {
    entry_index: usize,
    position: u64,
    is_open: bool,
    is_directory: bool,
};

// ── File Data Storage ─────────────────────────────────────────────────────────

var initfs_ram: [INITFS_RAM_SIZE]u8 = undefined;
var initfs_ram_used: usize = 0;

// ── InitFS Operations (FsOps interface) ───────────────────────────────────────

fn initfsOpen(file: *vfs.FileObject, path: []const u8, _access: vfs.FileAccessMode) vfs.FileStatus {
    _ = _access; // Explicitly discard unused access parameter
    const rel_path = stripMountPrefix(path);
    const entry_idx = findEntry(rel_path);
    if (entry_idx == null) {
        return .not_found;
    }

    const entry = &initfs_entries[entry_idx.?];

    // Check if it's a directory when opening without directory flag
    if (entry.is_directory) {
        // Allow opening directory, set enum cursor to 0
        file.dir_enum_next = 0;
    }

    file.fs_data = @intCast(entry_idx.?);
    file.file_size = if (entry.is_directory) 0 else entry.data.len;
    file.file_type = if (entry.is_directory) .directory else .regular;
    file.position = 0;

    // Find or allocate handle
    const h = allocHandle(entry_idx.?, entry.is_directory);
    if (h) |handle| {
        _ = handle; // handle stored in array
    }

    return .success;
}

fn initfsClose(file: *vfs.FileObject) vfs.FileStatus {
    const entry_idx = @as(usize, @intCast(file.fs_data));
    freeHandle(entry_idx);
    file.is_open = false;
    return .success;
}

fn initfsRead(file: *vfs.FileObject, buffer: []u8) vfs.ReadResult {
    const entry_idx = @as(usize, @intCast(file.fs_data));
    if (entry_idx >= initfs_entry_count) {
        return .{ .status = .not_found, .bytes_read = 0 };
    }

    const entry = &initfs_entries[entry_idx];
    if (entry.is_directory) {
        return .{ .status = .is_directory, .bytes_read = 0 };
    }

    const start = @as(usize, @intCast(file.position));
    const end = @min(start + buffer.len, entry.data.len);
    if (start >= entry.data.len) {
        return .{ .status = .end_of_file, .bytes_read = 0 };
    }

    const to_read = end - start;
    @memcpy(buffer[0..to_read], entry.data[start..end]);
    file.position += @as(u64, @intCast(to_read));

    return .{ .status = .success, .bytes_read = to_read };
}

fn initfsWrite(_file: *vfs.FileObject, _data: []const u8) vfs.WriteResult {
    _ = _file; // Explicitly discard unused file parameter
    _ = _data; // Explicitly discard unused data parameter
    return .{ .status = .not_implemented, .bytes_written = 0 };
}

fn initfsReaddir(file: *vfs.FileObject, entries: []vfs.DirEntry) usize {
    const entry_idx = @as(usize, @intCast(file.fs_data));
    if (entry_idx >= initfs_entry_count) return 0;

    const parent = &initfs_entries[entry_idx];
    if (!parent.is_directory) return 0;

    var count: usize = 0;
    var cursor = file.dir_enum_next;

    while (cursor < initfs_entry_count and count < entries.len) : (cursor += 1) {
        const child = &initfs_entries[cursor];
        if (child.parent_index != entry_idx) continue;

        // Skip hidden files in dir listing
        if (child.is_hidden) {
            continue;
        }

        var e = &entries[count];
        @memset(&e.name, 0);
        @memcpy(e.name[0..child.name_len], child.name[0..child.name_len]);
        e.name_len = child.name_len;
        e.file_type = if (child.is_directory) .directory else .regular;
        e.file_size = if (child.is_directory) 0 else child.data.len;
        e.attributes = .{};
        e.attributes.readonly = child.is_readonly;
        e.attributes.hidden = child.is_hidden;
        e.attributes.system = child.is_system;
        e.attributes.directory = child.is_directory;
        e.attributes.archive = child.is_archive;
        e.creation_time = child.creation_time;
        e.modification_time = child.modification_time;

        count += 1;
    }

    file.dir_enum_next = cursor;
    return count;
}

fn initfsMkdir(_path: []const u8) vfs.FileStatus {
    _ = _path;
    return .not_implemented;
}

fn initfsRemove(_path: []const u8) vfs.FileStatus {
    _ = _path;
    return .not_implemented;
}

fn initfsStat(path: []const u8, entry: *vfs.DirEntry) vfs.FileStatus {
    const rel_path = stripMountPrefix(path);
    const entry_idx = findEntry(rel_path);
    if (entry_idx == null) {
        return .not_found;
    }

    const e = &initfs_entries[entry_idx.?];
    @memset(&entry.name, 0);
    @memcpy(entry.name[0..e.name_len], e.name[0..e.name_len]);
    entry.name_len = e.name_len;
    entry.file_type = if (e.is_directory) .directory else .regular;
    entry.file_size = if (e.is_directory) 0 else e.data.len;
    entry.attributes = .{};
    entry.attributes.readonly = e.is_readonly;
    entry.attributes.hidden = e.is_hidden;
    entry.attributes.system = e.is_system;
    entry.attributes.directory = e.is_directory;
    entry.attributes.archive = e.is_archive;
    entry.creation_time = e.creation_time;
    entry.modification_time = e.modification_time;

    return .success;
}

fn initfsSeek(file: *vfs.FileObject, offset: i64, origin: vfs.SeekOrigin) vfs.FileStatus {
    const entry_idx = @as(usize, @intCast(file.fs_data));
    if (entry_idx >= initfs_entry_count) return .not_found;

    const entry = &initfs_entries[entry_idx];
    const size: i64 = @as(i64, @intCast(entry.data.len));

    var new_pos: i64 = switch (origin) {
        .begin => offset,
        .current => @as(i64, @intCast(file.position)) + offset,
        .end => size + offset,
    };

    if (new_pos < 0) new_pos = 0;
    if (new_pos > size) new_pos = size;

    file.position = @as(u64, @intCast(new_pos));
    return .success;
}

fn initfsQuerySpace(_mount_idx: u32, total: *u64, free: *u64) vfs.FileStatus {
    _ = _mount_idx;
    total.* = INITFS_RAM_SIZE;
    free.* = INITFS_RAM_SIZE - initfs_ram_used;
    return .success;
}

// ── InitFS FsOps ─────────────────────────────────────────────────────────────

const initfs_ops: vfs.FsOps = .{
    .open = initfsOpen,
    .close = initfsClose,
    .read = initfsRead,
    .write = initfsWrite,
    .readdir = initfsReaddir,
    .mkdir = initfsMkdir,
    .remove = initfsRemove,
    .stat = initfsStat,
    .seek = initfsSeek,
    .query_space = initfsQuerySpace,
};

// ── Helper Functions ──────────────────────────────────────────────────────────

fn getInitFSRootPrefix() []const u8 {
    if (initfs_mount_letter == 0) return "";
    return &[_]u8{ initfs_mount_letter, ':', '\\' };
}

fn stripMountPrefix(path: []const u8) []const u8 {
    const prefix = getInitFSRootPrefix();
    if (prefix.len > 0 and path.len >= prefix.len) {
        const norm_path = path;
        // Handle both "C:\" and "C:/" styles
        if ((norm_path[0] == initfs_mount_letter or norm_path[0] == initfs_mount_letter + 32) and
            norm_path[1] == ':')
        {
            const start: usize = if (norm_path[2] == '\\' or norm_path[2] == '/') 3 else 2;
            return norm_path[start..];
        }
    }
    return path;
}

fn allocHandle(entry_idx: usize, is_dir: bool) ?*InitFSHandle {
    for (&initfs_handles) |*h| {
        if (!h.is_open) {
            h.* = .{ .entry_index = entry_idx, .position = 0, .is_open = true, .is_directory = is_dir };
            return h;
        }
    }
    return null;
}

fn freeHandle(entry_idx: usize) void {
    for (&initfs_handles) |*h| {
        if (h.is_open and h.entry_index == entry_idx) {
            h.is_open = false;
            return;
        }
    }
}

fn findEntry(rel_path: []const u8) ?usize {
    if (rel_path.len == 0 or std.mem.eql(u8, rel_path, "\\") or std.mem.eql(u8, rel_path, "/")) {
        // Root of mount
        for (initfs_entries[0..initfs_entry_count], 0..) |e, idx| {
            if (e.parent_index == INITFS_ROOT_PARENT) {
                return idx;
            }
        }
        return null;
    }

    // Parse path components
    var components: [16][]const u8 = undefined;
    var comp_count: usize = 0;

    var remaining = rel_path;
    while (remaining.len > 0) {
        // Skip leading slashes
        while (remaining.len > 0 and (remaining[0] == '\\' or remaining[0] == '/')) {
            remaining = remaining[1..];
        }
        if (remaining.len == 0) break;

        // Find next slash
        var end: usize = 0;
        while (end < remaining.len and remaining[end] != '\\' and remaining[end] != '/') {
            end += 1;
        }

        if (comp_count < components.len) {
            components[comp_count] = remaining[0..end];
            comp_count += 1;
        }

        remaining = if (end < remaining.len) remaining[end + 1 ..] else "";
    }

    // Find matching entry by path
    var parent_idx: usize = INITFS_ROOT_PARENT;
    var found_idx: ?usize = null;

    for (0..comp_count) |i| {
        const comp = components[i];
        found_idx = null;

        for (initfs_entries[0..initfs_entry_count], 0..) |*e, idx| {
            if (e.parent_index != parent_idx) continue;
            if (e.name_len != comp.len) continue;
            if (!std.mem.eql(u8, e.name[0..e.name_len], comp)) continue;
            found_idx = idx;
            break;
        }

        if (found_idx == null) return null;
        parent_idx = found_idx.?;
    }

    return found_idx;
}

fn findEntryByName(name: []const u8, parent_idx: usize) ?usize {
    for (initfs_entries[0..initfs_entry_count], 0..) |*e, idx| {
        if (e.parent_index != parent_idx) continue;
        if (e.name_len != name.len) continue;
        if (!std.mem.eql(u8, e.name[0..e.name_len], name)) continue;
        return idx;
    }
    return null;
}

fn allocEntry(name: []const u8, is_dir: bool, parent_idx: usize) ?usize {
    if (initfs_entry_count >= MAX_INITFS_ENTRIES) return null;

    const idx = initfs_entry_count;
    initfs_entry_count += 1;

    var e = &initfs_entries[idx];
    e.* = .{};

    const copy_len = @min(name.len, e.name.len);
    @memcpy(e.name[0..copy_len], name[0..copy_len]);
    e.name_len = copy_len;
    e.is_directory = is_dir;
    e.parent_index = parent_idx;
    e.creation_time = 0x01D9_3A00_00000000; // 2026-01-01 00:00:00
    e.modification_time = e.creation_time;

    return idx;
}

fn setEntryData(idx: usize, data: []const u8) void {
    if (idx >= initfs_entry_count) return;
    initfs_entries[idx].data = data;
}

// ── Directory Tree Population ─────────────────────────────────────────────────

const ROOT_NAME = "";

fn createWindowsDirectoryTree() void {
    initfs_entry_count = 0;

    // Create root (will be named by mount prefix)
    _ = allocEntry(ROOT_NAME, true, INITFS_ROOT_PARENT);
    const root_idx = 0;
    _ = root_idx;

    // Helper to create directory and return its index
    const createDir = struct {
        fn f(parent: usize, name: []const u8) usize {
            if (allocEntry(name, true, parent)) |idx| return idx;
            return parent;
        }
    }.f;

    // Helper to create file
    const createFile = struct {
        fn f(parent: usize, name: []const u8, data: []const u8) void {
            if (allocEntry(name, false, parent)) |idx| {
                setEntryData(idx, data);
            }
        }
    }.f;

    // ── C:\Boot\ ──────────────────────────────────────────────────────────
    const boot = createDir(0, "Boot");
    createFile(boot, "BCD", "Windows Boot Configuration Data\r\n");

    // ── C:\PerfLogs\ ───────────────────────────────────────────────────────
    _ = createDir(0, "PerfLogs");

    // ── C:\Program Files\ ─────────────────────────────────────────────────
    const pf = createDir(0, "Program Files");
    {
        const ie = createDir(pf, "Internet Explorer");
        createFile(ie, "iexplore.exe", "MZ...PE Header for IE");

        const wmp = createDir(pf, "Windows Media Player");
        createFile(wmp, "wmplayer.exe", "MZ...PE Header for WMP");

        const acc = createDir(pf, "Accessories");
        {
            createDir(acc, "Notepad");
            createDir(acc, "Calculator");
            createDir(acc, "Paint");
            createDir(acc, "WordPad");
            createDir(acc, "System Information");
            createDir(acc, "Character Map");
            createDir(acc, "Snipping Tool");
            createDir(acc, "Remote Desktop Connection");
        }
    }

    // ── C:\Program Files (x86)\ ────────────────────────────────────────────
    _ = createDir(0, "Program Files (x86)");

    // ── C:\ProgramData\ ───────────────────────────────────────────────────
    const pd = createDir(0, "ProgramData");
    {
        const ms = createDir(pd, "Microsoft");
        const win = createDir(ms, "Windows");
        const sm = createDir(win, "Start Menu");
        const prog = createDir(sm, "Programs");
        _ = createDir(prog, "Accessories");
        _ = createDir(prog, "System Tools");
        _ = createDir(prog, "Maintenance");
    }

    // ── C:\Users\ ──────────────────────────────────────────────────────────
    const users = createDir(0, "Users");
    {
        // Default user
        const def = createDir(users, "Default");
        {
            const dd = createDir(def, "Desktop");
            _ = dd;
            const doc = createDir(def, "Documents");
            createFile(doc, "desktop.ini", "[Desktop Entry]\r\n");
            const appd = createDir(def, "AppData");
            _ = createDir(appd, "Local");
            _ = createDir(appd, "Roaming");
        }

        // Admin user
        const admin = createDir(users, "Administrator");
        {
            _ = createDir(admin, "Desktop");
            _ = createDir(admin, "Documents");
            _ = createDir(admin, "Downloads");
            _ = createDir(admin, "Pictures");
            _ = createDir(admin, "Music");
            _ = createDir(admin, "Videos");
            const admin_appd = createDir(admin, "AppData");
            _ = createDir(admin_appd, "Local");
            _ = createDir(admin_appd, "Roaming");
        }

        // Public user
        const public_user = createDir(users, "Public");
        {
            _ = createDir(public_user, "Desktop");
            _ = createDir(public_user, "Documents");
            _ = createDir(public_user, "Downloads");
            _ = createDir(public_user, "Pictures");
            _ = createDir(public_user, "Music");
            _ = createDir(public_user, "Videos");
        }
    }

    // ── C:\Windows\ ────────────────────────────────────────────────────────
    const windows = createDir(0, "Windows");
    {
        const system32 = createDir(windows, "System32");
        {
            // config subdirectory
            const cfg = createDir(system32, "config");
            {
                createFile(cfg, "system", "REGISTRY FILE\r\n");
                createFile(cfg, "software", "REGISTRY FILE\r\n");
                createFile(cfg, "sam", "REGISTRY FILE\r\n");
                createFile(cfg, "security", "REGISTRY FILE\r\n");
                createFile(cfg, "default", "REGISTRY FILE\r\n");
            }

            // drivers\etc subdirectory
            const drv = createDir(system32, "drivers");
            const etc = createDir(drv, "etc");
            {
                createFile(etc, "hosts", "127.0.0.1       localhost\n::1             localhost\n");
                createFile(etc, "services", "# Windows Services Configuration\n");
                createFile(etc, "networks", "# Network Configuration\n");
                createFile(etc, "protocol", "# Protocol Configuration\n");
            }

            // Executable files
            createFile(system32, "cmd.exe", "MZ...PE Header for CMD");
            createFile(system32, "notepad.exe", "MZ...PE Header for Notepad");
            createFile(system32, "calc.exe", "MZ...PE Header for Calculator");
            createFile(system32, "regedit.exe", "MZ...PE Header for Registry Editor");
            createFile(system32, "msconfig.exe", "MZ...PE Header for MSConfig");
            createFile(system32, "taskmgr.exe", "MZ...PE Header for Task Manager");
            createFile(system32, "explorer.exe", "MZ...PE Header for Explorer");
            createFile(system32, "hostname.exe", "MZ...PE Header for Hostname");
            createFile(system32, "ipconfig.exe", "MZ...PE Header for IPConfig");
            createFile(system32, "ping.exe", "MZ...PE Header for Ping");
            createFile(system32, "net.exe", "MZ...PE Header for Net");
            createFile(system32, "sc.exe", "MZ...PE Header for Service Control");
            createFile(system32, "wininit.exe", "MZ...PE Header for WinInit");
            createFile(system32, "winlogon.exe", "MZ...PE Header for Winlogon");
            createFile(system32, "services.exe", "MZ...PE Header for Services");
            createFile(system32, "lsass.exe", "MZ...PE Header for LSASS");
            createFile(system32, "svchost.exe", "MZ...PE Header for SVCHOST");
            createFile(system32, "dwm.exe", "MZ...PE Header for DWM");
            createFile(system32, "userinit.exe", "MZ...PE Header for UserInit");
            createFile(system32, "msiexec.exe", "MZ...PE Header for MSI Installer");
            createFile(system32, "rundll32.exe", "MZ...PE Header for Rundll32");
            createFile(system32, "conhost.exe", "MZ...PE Header for Console Host");
            createFile(system32, "ctfmon.exe", "MZ...PE Header for CTF Monitor");
            createFile(system32, "smss.exe", "MZ...PE Header for SMSS");
            createFile(system32, "csrss.exe", "MZ...PE Header for CSRSS");
            createFile(system32, "win32k.sys", "MZ...PE Header for Win32K");

            // DLL files
            createFile(system32, "ntdll.dll", "MZ...PE Header for NTDLL");
            createFile(system32, "kernel32.dll", "MZ...PE Header for KERNEL32");
            createFile(system32, "kernelbase.dll", "MZ...PE Header for KERNELBASE");
            createFile(system32, "user32.dll", "MZ...PE Header for USER32");
            createFile(system32, "gdi32.dll", "MZ...PE Header for GDI32");
            createFile(system32, "advapi32.dll", "MZ...PE Header for ADVAPI32");
            createFile(system32, "shell32.dll", "MZ...PE Header for SHELL32");
            createFile(system32, "shcore.dll", "MZ...PE Header for SHCORE");
            createFile(system32, "ole32.dll", "MZ...PE Header for OLE32");
            createFile(system32, "comctl32.dll", "MZ...PE Header for COMCTL32");
            createFile(system32, "comdlg32.dll", "MZ...PE Header for COMDLG32");
            createFile(system32, "urlmon.dll", "MZ...PE Header for URLMON");
            createFile(system32, "wininet.dll", "MZ...PE Header for WININET");
            createFile(system32, "setupapi.dll", "MZ...PE Header for SETUPAPI");
            createFile(system32, "cfgmgr32.dll", "MZ...PE Header for CFGMGR32");
            createFile(system32, "sechost.dll", "MZ...PE Header for SECHOST");
            createFile(system32, "rpcrt4.dll", "MZ...PE Header for RPCRT4");
            createFile(system32, "sspicli.dll", "MZ...PE Header for SSPICLI");
            createFile(system32, "cryptbase.dll", "MZ...PE Header for CRYPTBASE");
            createFile(system32, "bcryptprimitives.dll", "MZ...PE Header for BCRYPT");
            createFile(system32, "msvcrt.dll", "MZ...PE Header for MSVCRT");
            createFile(system32, "ucrtbase.dll", "MZ...PE Header for UCRT");
            createFile(system32, "vcruntime140.dll", "MZ...PE Header for VCRUNTIME");
            createFile(system32, "imm32.dll", "MZ...PE Header for IMM32");
            createFile(system32, "ddraw.dll", "MZ...PE Header for DDRAW");
            createFile(system32, "dinput8.dll", "MZ...PE Header for DINPUT8");
            createFile(system32, "dxapi.sys", "MZ...PE Header for DXAPI");

            // config\RegBack subdirectory (registry backups)
            const regback = createDir(cfg, "RegBack");
            {
                createFile(regback, "system", "REGISTRY BACKUP\r\n");
                createFile(regback, "software", "REGISTRY BACKUP\r\n");
                createFile(regback, "sam", "REGISTRY BACKUP\r\n");
                createFile(regback, "security", "REGISTRY BACKUP\r\n");
                createFile(regback, "default", "REGISTRY BACKUP\r\n");
            }
        }

        // SysWOW64
        _ = createDir(windows, "SysWOW64");

        // Resources
        const resources = createDir(windows, "Resources");
        const themes = createDir(resources, "Themes");
        {
            createFile(themes, "aero.theme", "[Theme]\r\n");
            createFile(themes, "classic.theme", "[Theme]\r\n");
            createFile(themes, "basic.theme", "[Theme]\r\n");
            _ = createDir(themes, "DesktopBackground");
        }

        // Temp directory
        _ = createDir(windows, "Temp");

        // Logs directory
        _ = createDir(windows, "Logs");

        // WinSxS
        _ = createDir(windows, "WinSxS");

        // Panther (setup logs)
        _ = createDir(windows, "Panther");

        // Migration (post-setup migration)
        _ = createDir(windows, "Migration");

        // System32\Tasks (Scheduled Tasks)
        const tasks = createDir(system32, "Tasks");
        _ = createDir(tasks, "Microsoft");
        _ = createDir(tasks, "Microsoft\\Windows");
    }

    klog.info("InitFS: Created %u directory/file entries", .{initfs_entry_count});
}

// ── Public API ───────────────────────────────────────────────────────────────

pub fn init() void {
    if (initfs_initialized) return;

    // Initialize entry array
    for (&initfs_entries) |*e| {
        e.* = .{};
    }

    // Initialize handles
    for (&initfs_handles) |*h| {
        h.* = .{};
    }

    // Create directory tree
    createWindowsDirectoryTree();

    initfs_initialized = true;
    klog.info("InitFS: Initialized with %u entries", .{initfs_entry_count});
}

pub fn mountAsDrive(letter: u8) vfs.FileStatus {
    if (initfs_mounted) return .already_exists;

    var prefix_buf: [8]u8 = undefined;
    prefix_buf[0] = letter;
    prefix_buf[1] = ':';
    prefix_buf[2] = '\\';
    const prefix = prefix_buf[0..3];

    const label = "ZirconOS";

    const result = vfs.mount(prefix, .unknown, initfs_ops, 0, label);

    if (result == .success) {
        initfs_mounted = true;
        initfs_mount_letter = letter;
        initfs_mount_idx = @intCast(vfs.getMountCount() - 1);
        klog.info("InitFS: Mounted as %c: drive", .{letter});
    }

    return result;
}

pub fn isMounted() bool {
    return initfs_mounted;
}

pub fn getMountLetter() u8 {
    return initfs_mount_letter;
}

pub fn getEntryCount() usize {
    return initfs_entry_count;
}

// ── Directory Listing for Explorer ───────────────────────────────────────────

pub const InitFSListEntry = struct {
    name: [64]u8,
    name_len: usize,
    is_directory: bool,
    is_system: bool,
    is_hidden: bool,
    file_size: u64,
};

pub fn listRoot() []InitFSListEntry {
    _ = initfs_ram;
    return &[_]InitFSListEntry{};
}

pub fn getChildEntries(parent_name: []const u8, max_count: usize, out: []InitFSListEntry) usize {
    const parent_idx = if (parent_name.len == 0)
        INITFS_ROOT_PARENT
    else
        findEntry(parent_name) orelse return 0;

    var count: usize = 0;
    for (initfs_entries[0..initfs_entry_count]) |*e| {
        if (e.parent_index != parent_idx) continue;
        if (count >= max_count) break;

        var entry = &out[count];
        @memset(&entry.name, 0);
        @memcpy(entry.name[0..e.name_len], e.name[0..e.name_len]);
        entry.name_len = e.name_len;
        entry.is_directory = e.is_directory;
        entry.is_system = e.is_system;
        entry.is_hidden = e.is_hidden;
        entry.file_size = e.data.len;

        count += 1;
    }

    return count;
}
