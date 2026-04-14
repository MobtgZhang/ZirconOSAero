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
// Module: src/desktop/applications/ie_browser/download_manager.zig
// Purpose: Download queue and progress management for IE browser
//
// This is an independent clean-room implementation.

const std = @import("std");
const klog = @import("../../../rtl/klog.zig");

pub const MaxDownloads = 20;
pub const MaxPathLen = 512;

pub const DownloadState = enum { pending, downloading, paused, completed, failed, cancelled };

pub const DownloadItem = struct {
    id: u32,
    url: [2048]u8,
    url_len: usize,
    filename: [256]u8,
    filename_len: usize,
    save_path: [MaxPathLen]u8,
    save_path_len: usize,
    state: DownloadState,
    progress: i32,
    total_bytes: u64,
    received_bytes: u64,
    speed_bps: u64,
    started_at: u64,
    completed_at: u64,
    error_message: [128]u8,
    error_len: usize,
};

pub const DownloadManager = struct {
    downloads: [MaxDownloads]DownloadItem,
    download_count: usize,
    next_id: u32,
    max_concurrent: usize,
    auto_open: bool,

    pub fn create() DownloadManager {
        return .{
            .downloads = undefined,
            .download_count = 0,
            .next_id = 1,
            .max_concurrent = 3,
            .auto_open = false,
        };
    }

    pub fn addDownload(dm: *DownloadManager, url: []const u8, save_path: []const u8) ?*DownloadItem {
        if (dm.download_count >= MaxDownloads) return null;

        var item = &dm.downloads[dm.download_count];
        item.id = dm.next_id;
        dm.next_id += 1;

        item.url_len = @min(url.len, item.url.len - 1);
        @memcpy(&item.url, url[0..item.url_len]);
        item.url[item.url_len] = 0;

        // Extract filename from URL
        const lastSlash = std.mem.lastIndexOfScalar(u8, url, '/');
        if (lastSlash) |idx| {
            const name_part = url[idx + 1..];
            item.filename_len = @min(name_part.len, item.filename.len - 1);
            @memcpy(&item.filename, name_part[0..item.filename_len]);
            item.filename[item.filename_len] = 0;
        } else {
            item.filename_len = 4;
            @memcpy(&item.filename, "file");
            item.filename[4] = 0;
        }

        item.save_path_len = @min(save_path.len, item.save_path.len - 1);
        @memcpy(&item.save_path, save_path[0..item.save_path_len]);
        item.save_path[item.save_path_len] = 0;

        item.state = .pending;
        item.progress = 0;
        item.total_bytes = 0;
        item.received_bytes = 0;
        item.speed_bps = 0;
        item.started_at = 0;
        item.completed_at = 0;
        item.error_len = 0;

        dm.download_count += 1;
        return item;
    }

    pub fn removeDownload(dm: *DownloadManager, id: u32) bool {
        var i: usize = 0;
        while (i < dm.download_count) : (i += 1) {
            if (dm.downloads[i].id == id) {
                // Shift remaining downloads
                var j: usize = i;
                while (j < dm.download_count - 1) : (j += 1) {
                    dm.downloads[j] = dm.downloads[j + 1];
                }
                dm.download_count -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn getDownload(dm: *const DownloadManager, id: u32) ?*DownloadItem {
        for (dm.downloads[0..dm.download_count]) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }

    pub fn pauseDownload(dm: *DownloadManager, id: u32) bool {
        if (dm.getDownload(id)) |item| {
            if (item.state == .downloading) {
                item.state = .paused;
                return true;
            }
        }
        return false;
    }

    pub fn resumeDownload(dm: *DownloadManager, id: u32) bool {
        if (dm.getDownload(id)) |item| {
            if (item.state == .paused) {
                item.state = .downloading;
                return true;
            }
        }
        return false;
    }

    pub fn cancelDownload(dm: *DownloadManager, id: u32) bool {
        if (dm.getDownload(id)) |item| {
            item.state = .cancelled;
            return true;
        }
        return false;
    }

    pub fn getActiveDownloads(dm: *const DownloadManager) []const DownloadItem {
        var result: [MaxDownloads]DownloadItem = undefined;
        var idx: usize = 0;
        for (dm.downloads[0..dm.download_count]) |*item| {
            if (item.state == .downloading or item.state == .pending) {
                result[idx] = item.*;
                idx += 1;
            }
        }
        return result[0..idx];
    }

    pub fn getAllDownloads(dm: *const DownloadManager) []const DownloadItem {
        return dm.downloads[0..dm.download_count];
    }

    pub fn clearCompleted(dm: *DownloadManager) void {
        var i: usize = 0;
        while (i < dm.download_count) : (i += 1) {
            if (dm.downloads[i].state == .completed or dm.downloads[i].state == .cancelled) {
                dm.removeDownload(dm.downloads[i].id);
                if (i > 0) i -= 1;
            }
        }
    }
};
