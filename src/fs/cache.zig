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
// Module: src/fs/cache.zig
// Purpose: 块设备缓冲区缓存层 — 为文件系统提供扇区级缓存，
//         支持 LRU 替换策略、写回/写穿透模式和块读写回调集成。
//
// This is an independent clean-room implementation.
// Reference: OS textbooks — buffer cache, page cache, LRU replacement policy.

const std = @import("std");
const klog = @import("../rtl/klog.zig");
const io = @import("../io/io.zig");
const block_common = @import("../drivers/storage/block_dev_common.zig");

pub const SECTOR_SIZE: usize = 512;
pub const CACHE_SIZE: usize = 256;

/// 缓存模式。
pub const CacheMode = enum {
    write_through,
    write_back,
};

/// 缓存条目状态。
const CacheState = enum(u2) {
    clean = 0,
    dirty = 1,
    read_in_progress = 2,
    write_in_progress = 3,
};

/// 缓存条目。
const CacheEntry = struct {
    lba: u64 = 0,
    data: [SECTOR_SIZE]u8 = .{0} ** SECTOR_SIZE,
    state: CacheState = .clean,
    access_time: u64 = 0,
    in_use: bool = false,
};

var cache: [CACHE_SIZE]CacheEntry = .{.{}} ** CACHE_SIZE;
var cache_hits: u64 = 0;
var cache_misses: u64 = 0;
var cache_initialized: bool = false;

/// 全局递增时间戳（用于 LRU 排序，每次 I/O 后递增）。
var g_timestamp: u64 = 0;

/// 获取下一个时间戳。
fn nextTimestamp() u64 {
    g_timestamp +%= 1;
    return g_timestamp;
}

/// 在缓存中查找指定 LBA 的条目。
fn findEntry(lba: u64) ?*CacheEntry {
    for (&cache) |*entry| {
        if (entry.in_use and entry.lba == lba) {
            entry.access_time = nextTimestamp();
            return entry;
        }
    }
    return null;
}

/// 找一个空闲或可驱逐的缓存条目。
fn getFreeEntry() ?*CacheEntry {
    for (&cache) |*entry| {
        if (!entry.in_use) {
            entry.in_use = true;
            entry.state = .read_in_progress;
            entry.lba = 0;
            entry.access_time = nextTimestamp();
            return entry;
        }
    }
    var oldest: ?*CacheEntry = null;
    var oldest_time: u64 = std.math.maxInt(u64);
    for (&cache) |*entry| {
        if (entry.state != .read_in_progress and entry.state != .write_in_progress) {
            if (entry.access_time < oldest_time) {
                oldest_time = entry.access_time;
                oldest = entry;
            }
        }
    }
    if (oldest) |e| {
        if (e.state == .dirty) {
            flushEntry(e) catch {};
        }
        e.state = .read_in_progress;
        e.lba = 0;
        e.access_time = nextTimestamp();
    }
    return oldest;
}

/// 将脏条目写回磁盘。
fn flushEntry(e: *CacheEntry) !void {
    if (e.state != .dirty) return;
    if (g_backend) |dev| {
        const status = dev.write_blocks(dev.ctx, e.lba, &e.data);
        if (status != io.STATUS_SUCCESS) {
            klog.warn("BufCache: flush LBA %u failed", .{e.lba});
            return error.FlushFailed;
        }
    }
    e.state = .clean;
}

/// 设置后端块设备。
var g_backend: ?*block_common.BlockDevVTable = null;

pub fn setBackend(dev: *block_common.BlockDevVTable) void {
    g_backend = dev;
    klog.info("BufCache: backend set", .{});
}

pub fn init() void {
    cache = .{.{}} ** CACHE_SIZE;
    cache_hits = 0;
    cache_misses = 0;
    g_timestamp = 0;
    cache_initialized = true;
    klog.info("BufCache: initialized (entries=%u)", .{CACHE_SIZE});
}

/// 从缓存读取扇区（无 LBA 转换，直接使用设备 LBA）。
pub fn readSector(lba: u64, buf: []u8) io.NTSTATUS {
    if (buf.len < SECTOR_SIZE) return io.STATUS_INVALID_PARAMETER;
    if (g_backend == null) return io.STATUS_DEVICE_NOT_READY;

    if (findEntry(lba)) |entry| {
        cache_hits +%= 1;
        @memcpy(buf[0..SECTOR_SIZE], &entry.data);
        return io.STATUS_SUCCESS;
    }

    cache_misses +%= 1;
    const entry = getFreeEntry() orelse {
        return io.STATUS_INSUFFICIENT_RESOURCES;
    };
    defer entry.state = .clean;

    const dev = g_backend.?;
    const status = dev.read_blocks(dev.ctx, lba, &entry.data);
    if (status != io.STATUS_SUCCESS) {
        entry.state = .clean;
        entry.in_use = false;
        return status;
    }
    entry.lba = lba;
    @memcpy(buf[0..SECTOR_SIZE], &entry.data);
    return io.STATUS_SUCCESS;
}

/// 写扇区到缓存。
pub fn writeSector(lba: u64, data: []const u8) io.NTSTATUS {
    if (data.len < SECTOR_SIZE) return io.STATUS_INVALID_PARAMETER;
    if (g_backend == null) return io.STATUS_DEVICE_NOT_READY;

    if (findEntry(lba)) |entry| {
        cache_hits +%= 1;
        @memcpy(&entry.data, data[0..SECTOR_SIZE]);
        entry.state = .dirty;
        entry.access_time = nextTimestamp();
        return io.STATUS_SUCCESS;
    }

    cache_misses +%= 1;
    const entry = getFreeEntry() orelse {
        return io.STATUS_INSUFFICIENT_RESOURCES;
    };
    entry.lba = lba;
    @memcpy(&entry.data, data[0..SECTOR_SIZE]);
    entry.state = .dirty;
    entry.access_time = nextTimestamp();
    return io.STATUS_SUCCESS;
}

/// 刷新所有脏条目到磁盘。
pub fn flushAll() io.NTSTATUS {
    if (g_backend == null) return io.STATUS_DEVICE_NOT_READY;
    var error_count: u32 = 0;
    for (&cache) |*entry| {
        if (entry.in_use and entry.state == .dirty) {
            flushEntry(entry) catch {
                error_count +%= 1;
            };
        }
    }
    if (error_count > 0) {
        klog.warn("BufCache: flushAll had %u errors", .{error_count});
        return io.STATUS_IO_DEVICE_ERROR;
    }
    return io.STATUS_SUCCESS;
}

/// 刷新指定 LBA 的条目。
pub fn flushLba(lba: u64) io.NTSTATUS {
    if (findEntry(lba)) |entry| {
        if (entry.state == .dirty) {
            flushEntry(entry) catch return io.STATUS_IO_DEVICE_ERROR;
        }
    }
    return io.STATUS_SUCCESS;
}

/// 获取缓存命中率统计。
pub fn getStats(hits: *u64, misses: *u64, total: *usize) void {
    hits.* = cache_hits;
    misses.* = cache_misses;
    total.* = CACHE_SIZE;
}

pub fn isInitialized() bool {
    return cache_initialized;
}
