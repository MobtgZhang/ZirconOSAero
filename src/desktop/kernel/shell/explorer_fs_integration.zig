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

//! Explorer File System Integration - Windows 7 Style Deep Traversal and Metadata
//!
//! Implements deep filesystem operations including recursive directory traversal,
//! file type detection, metadata extraction, and virtual folder support.
//! Clean-room implementation based on publicly documented Windows 7 Explorer behavior.

const std = @import("std");
const vfs = @import("../../../fs/vfs.zig");
const explorer_vol_snap = @import("../../../fs/explorer_volume_snapshot.zig");

// ── File Type Detection ───────────────────────────────────────────────────────

pub const FileCategory = enum {
    unknown,
    document,
    image,
    video,
    audio,
    archive,
    executable,
    shortcut,
    folder,
};

pub const KNOWN_EXTENSIONS = struct {
    pub const documents = [_][]const u8{ "doc", "docx", "pdf", "txt", "rtf", "odt", "xls", "xlsx", "ppt", "pptx" };
    pub const images = [_][]const u8{ "jpg", "jpeg", "png", "gif", "bmp", "ico", "svg", "webp", "tiff" };
    pub const videos = [_][]const u8{ "mp4", "avi", "mkv", "mov", "wmv", "flv", "webm" };
    pub const audio = [_][]const u8{ "mp3", "wav", "flac", "aac", "ogg", "wma", "m4a" };
    pub const archives = [_][]const u8{ "zip", "rar", "7z", "tar", "gz", "bz2" };
    pub const executables = [_][]const u8{ "exe", "dll", "sys", "bat", "cmd", "msi" };
    pub const shortcuts = [_][]const u8{ "lnk", "url" };
};

pub fn detectFileCategory(extension: []const u8) FileCategory {
    const ext_lower = std.ascii.lowerString(&[16]u8{}, extension);
    
    for (KNOWN_EXTENSIONS.documents) |ext| {
        if (std.mem.eql(u8, ext_lower[0..extension.len], ext)) {
            return .document;
        }
    }
    for (KNOWN_EXTENSIONS.images) |ext| {
        if (std.mem.eql(u8, ext_lower[0..extension.len], ext)) {
            return .image;
        }
    }
    for (KNOWN_EXTENSIONS.videos) |ext| {
        if (std.mem.eql(u8, ext_lower[0..extension.len], ext)) {
            return .video;
        }
    }
    for (KNOWN_EXTENSIONS.audio) |ext| {
        if (std.mem.eql(u8, ext_lower[0..extension.len], ext)) {
            return .audio;
        }
    }
    for (KNOWN_EXTENSIONS.archives) |ext| {
        if (std.mem.eql(u8, ext_lower[0..extension.len], ext)) {
            return .archive;
        }
    }
    for (KNOWN_EXTENSIONS.executables) |ext| {
        if (std.mem.eql(u8, ext_lower[0..extension.len], ext)) {
            return .executable;
        }
    }
    for (KNOWN_EXTENSIONS.shortcuts) |ext| {
        if (std.mem.eql(u8, ext_lower[0..extension.len], ext)) {
            return .shortcut;
        }
    }
    
    return .unknown;
}

pub fn getFileTypeDescription(extension: []const u8, is_directory: bool) []const u8 {
    if (is_directory) {
        return "File folder";
    }
    
    const category = detectFileCategory(extension);
    
    return switch (category) {
        .document => "Document",
        .image => "Image",
        .video => "Video",
        .audio => "Audio",
        .archive => "Compressed Archive",
        .executable => "Application",
        .shortcut => "Shortcut",
        .folder => "File folder",
        .unknown => "File",
    };
}

pub fn getFileTypeFromName(name: []const u8) []const u8 {
    // Extract extension
    for (name, 0..) |c, idx| {
        if (c == '.') {
            return name[idx + 1..];
        }
    }
    return "";
}

// ── Folder Size Calculation ─────────────────────────────────────────────────────

const MAX_RECURSE_DEPTH = 16;

pub fn calculateFolderSize(letter: u8, subpath: ?[]const u8) u64 {
    var total_size: u64 = 0;
    calculateFolderSizeRecursive(letter, subpath, 0, &total_size);
    return total_size;
}

fn calculateFolderSizeRecursive(letter: u8, subpath: ?[]const u8, depth: usize, total_size: *u64) void {
    if (depth >= MAX_RECURSE_DEPTH) return;
    
    var entries: [64]explorer_vol_snap.ExplorerListEntry = undefined;
    const count = explorer_vol_snap.readDirectoryGeneric(
        letter,
        subpath,
        entries[0..],
        .name,
        true,
    );
    
    for (entries[0..count]) |entry| {
        if (entry.is_directory) {
            // Recurse into subdirectory
            const new_subpath = buildSubpath(subpath, entry.name[0..entry.name_len]);
            calculateFolderSizeRecursive(letter, new_subpath, depth + 1, total_size);
        } else {
            total_size.* += entry.file_size;
        }
    }
}

fn buildSubpath(parent: ?[]const u8, child: []const u8) []u8 {
    var buf: [256]u8 = undefined;
    var offset: usize = 0;
    
    if (parent) |p| {
        @memcpy(buf[0..p.len], p);
        offset = p.len;
        if (offset < buf.len) {
            buf[offset] = '\\';
            offset += 1;
        }
    }
    
    const copy_len = @min(child.len, buf.len - offset);
    @memcpy(buf[offset..][0..copy_len], child[0..copy_len]);
    offset += copy_len;
    
    return buf[0..offset];
}

// ── Deep Directory Traversal ────────────────────────────────────────────────────

const MAX_TRAVERSAL_ENTRIES = 1024;

pub const TraversalEntry = struct {
    name: []const u8,
    path: []const u8,
    is_directory: bool,
    size: u64,
    modified_time: u64,
};

pub const TraversalResult = struct {
    entries: []TraversalEntry,
    count: usize,
    total_size: u64,
    has_error: bool,
    error_msg: []const u8,
};

pub fn traverseDirectory(letter: u8, root_path: []const u8, max_depth: usize) TraversalResult {
    var entries: [MAX_TRAVERSAL_ENTRIES]TraversalEntry = undefined;
    var count: usize = 0;
    var total_size: u64 = 0;
    
    traverseRecursive(letter, root_path, 0, max_depth, &entries, &count, &total_size);
    
    return .{
        .entries = entries[0..count],
        .count = count,
        .total_size = total_size,
        .has_error = false,
        .error_msg = "",
    };
}

fn traverseRecursive(
    letter: u8,
    current_path: []const u8,
    depth: usize,
    max_depth: usize,
    entries: *[MAX_TRAVERSAL_ENTRIES]TraversalEntry,
    count: *usize,
    total_size: *u64,
) void {
    if (depth >= max_depth or count.* >= MAX_TRAVERSAL_ENTRIES) return;
    
    var dir_entries: [64]explorer_vol_snap.ExplorerListEntry = undefined;
    const subpath = if (current_path.len > 0) current_path else null;
    const n = explorer_vol_snap.readDirectoryGeneric(letter, subpath, dir_entries[0..], .name, true);
    
    for (dir_entries[0..n]) |entry| {
        if (count.* >= MAX_TRAVERSAL_ENTRIES) break;
        
        entries[count.*] = .{
            .name = entry.name[0..entry.name_len],
            .path = current_path,
            .is_directory = entry.is_directory,
            .size = entry.file_size,
            .modified_time = entry.modification_time,
        };
        count.* += 1;
        total_size.* += entry.file_size;
        
        if (entry.is_directory) {
            const new_path = buildSubpath(current_path, entry.name[0..entry.name_len]);
            traverseRecursive(letter, new_path, depth + 1, max_depth, entries, count, total_size);
        }
    }
}

// ── Virtual Folders ────────────────────────────────────────────────────────────

pub const VirtualFolder = enum {
    libraries,
    computer,
    network,
    recycle_bin,
    control_panel,
    printers,
};

pub const VirtualFolderInfo = struct {
    kind: VirtualFolder,
    name: []const u8,
    description: []const u8,
    icon: u8,
};

pub fn getVirtualFolderInfo(kind: VirtualFolder) VirtualFolderInfo {
    return switch (kind) {
        .libraries => .{
            .kind = .libraries,
            .name = "Libraries",
            .description = "Access your libraries",
            .icon = 0,
        },
        .computer => .{
            .kind = .computer,
            .name = "Computer",
            .description = "Browse files and folders on this computer",
            .icon = 0,
        },
        .network => .{
            .kind = .network,
            .name = "Network",
            .description = "Browse network locations",
            .icon = 0,
        },
        .recycle_bin => .{
            .kind = .recycle_bin,
            .name = "Recycle Bin",
            .description = "Deleted files",
            .icon = 0,
        },
        .control_panel => .{
            .kind = .control_panel,
            .name = "Control Panel",
            .description = "System settings",
            .icon = 0,
        },
        .printers => .{
            .kind = .printers,
            .name = "Printers",
            .description = "Manage printers",
            .icon = 0,
        },
    };
}

// ── Recycle Bin Operations ─────────────────────────────────────────────────────

pub fn getRecycleBinPath() []const u8 {
    return "$Recycle.Bin\\";
}

pub fn moveToRecycleBin(letter: u8, file_path: []const u8) bool {
    // In a real implementation, this would:
    // 1. Check if Recycle Bin exists
    // 2. Create a unique name for the deleted file
    // 3. Move the file to Recycle Bin
    // For now, this is a stub
    _ = letter;
    _ = file_path;
    return true;
}

pub fn restoreFromRecycleBin(letter: u8, deleted_path: []const u8, original_location: []const u8) bool {
    // In a real implementation, this would:
    // 1. Read the recycle bin entry
    // 2. Move the file back to its original location
    // For now, this is a stub
    _ = letter;
    _ = deleted_path;
    _ = original_location;
    return true;
}

pub fn emptyRecycleBin() void {
    // In a real implementation, this would delete all files in the Recycle Bin
}

// ── File Attributes ────────────────────────────────────────────────────────────

pub const FileAttributes = packed struct {
    readonly: bool,
    hidden: bool,
    system: bool,
    archive: bool,
    directory: bool,
};

pub fn parseFileAttributes(attr_byte: u8) FileAttributes {
    return .{
        .readonly = (attr_byte & 0x01) != 0,
        .hidden = (attr_byte & 0x02) != 0,
        .system = (attr_byte & 0x04) != 0,
        .archive = (attr_byte & 0x20) != 0,
        .directory = (attr_byte & 0x10) != 0,
    };
}

pub fn formatAttributesString(attrs: FileAttributes) []const u8 {
    // Windows-style attribute string (e.g., "A" for Archive, "RH" for Read-only Hidden)
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    
    if (attrs.directory) {
        buf[len] = 'D';
        len += 1;
    }
    if (attrs.readonly) {
        buf[len] = 'R';
        len += 1;
    }
    if (attrs.hidden) {
        buf[len] = 'H';
        len += 1;
    }
    if (attrs.system) {
        buf[len] = 'S';
        len += 1;
    }
    if (attrs.archive) {
        buf[len] = 'A';
        len += 1;
    }
    
    if (len == 0) {
        return "";
    }
    
    return buf[0..len];
}

// ── Network Share Browsing (Stub) ─────────────────────────────────────────────

pub const NetworkShare = struct {
    name: []const u8,
    path: []const u8,
    accessible: bool,
};

pub fn discoverNetworkShares() []NetworkShare {
    // Stub for SMB share discovery
    // In a real implementation, this would use SMB protocol
    return &[_]NetworkShare{};
}
