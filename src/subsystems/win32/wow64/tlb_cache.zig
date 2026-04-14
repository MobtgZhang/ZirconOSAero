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
// Module: src/subsystems/win32/wow64/tlb_cache.zig
// Purpose: Translation Block Cache - shared implementation for all DBT engines.

const ntdll = @import("../../../libs/ntdll.zig");

pub const MAX_TB_CACHE_ENTRIES: usize = 4096;
pub const MAX_JMP_CACHE_ENTRIES: usize = 1024;

pub const TranslationBlockState = enum(u8) {
    unused,
    compiling,
    ready,
    invalidated,
};

pub const TranslationBlock = struct {
    x86_addr: u32,
    host_addr: u64,
    code_size: usize,
    insn_count: usize,
    state: TranslationBlockState = .unused,
    last_access: u64 = 0,
    is_syscall_block: bool = false,
    next: ?*TranslationBlock = null,
    code: [*]u8,
};

pub const JmpCacheEntry = struct {
    x86_addr: u32,
    target_addr: u64,
    valid: bool = false,
};

pub const TranslationCache = struct {
    entries: [MAX_TB_CACHE_ENTRIES]TranslationBlock,
    jmp_entries: [MAX_JMP_CACHE_ENTRIES]JmpCacheEntry,
    lru_counter: u64 = 0,
    total_lookups: u64 = 0,
    total_hits: u64 = 0,
    total_misses: u64 = 0,

    pub fn init() TranslationCache {
        var cache = TranslationCache{
            .entries = undefined,
            .jmp_entries = undefined,
        };
        @memset(@as([*]u8, @ptrCast(&cache.entries))[0..@sizeOf(@TypeOf(cache.entries))], 0);
        @memset(@as([*]u8, @ptrCast(&cache.jmp_entries))[0..@sizeOf(@TypeOf(cache.jmp_entries))], 0);
        return cache;
    }

    pub fn lookup(self: *TranslationCache, x86_addr: u32) ?*TranslationBlock {
        self.total_lookups += 1;
        for (&self.entries) |*entry| {
            if (entry.state == .ready and entry.x86_addr == x86_addr) {
                entry.last_access = self.lru_counter;
                self.lru_counter +%= 1;
                self.total_hits += 1;
                return entry;
            }
        }
        self.total_misses += 1;
        return null;
    }

    pub fn insert(self: *TranslationCache, x86_addr: u32, host_code: [*]u8, code_size: usize, insn_count: usize) ?*TranslationBlock {
        var victim: ?*TranslationBlock = null;
        var oldest: u64 = self.lru_counter;

        for (&self.entries) |*entry| {
            if (entry.state == .unused) {
                victim = entry;
                break;
            }
            if (entry.last_access < oldest) {
                oldest = entry.last_access;
                victim = entry;
            }
        }

        if (victim) |v| {
            v.x86_addr = x86_addr;
            v.host_addr = @intFromPtr(host_code);
            v.code_size = code_size;
            v.insn_count = insn_count;
            v.state = .ready;
            v.last_access = self.lru_counter;
            self.lru_counter +%= 1;
            return v;
        }
        return null;
    }

    pub fn invalidate(self: *TranslationCache, x86_addr: u32) void {
        for (&self.entries) |*entry| {
            if (entry.x86_addr == x86_addr) {
                entry.state = .invalidated;
            }
        }
    }

    pub fn invalidateAll(self: *TranslationCache) void {
        for (&self.entries) |*entry| {
            entry.state = .unused;
        }
    }

    pub fn jmpLookup(self: *TranslationCache, x86_addr: u32) ?u64 {
        const idx = jmpHashIndex(x86_addr);
        const entry = &self.jmp_entries[idx];
        if (entry.valid and entry.x86_addr == x86_addr) {
            return entry.target_addr;
        }
        return null;
    }

    fn jmpHashIndex(x86_addr: u32) usize {
        const x = @as(u32, x86_addr);
        const h = x ^ (x >> 12) ^ (x >> 24);
        return @as(usize, h) % MAX_JMP_CACHE_ENTRIES;
    }

    pub fn jmpInsert(self: *TranslationCache, x86_addr: u32, target_addr: u64) void {
        const idx = jmpHashIndex(x86_addr);
        self.jmp_entries[idx] = .{
            .x86_addr = x86_addr,
            .target_addr = target_addr,
            .valid = true,
        };
    }

    pub fn getHitRate(self: *const TranslationCache) f64 {
        if (self.total_lookups == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_hits)) / @as(f64, @floatFromInt(self.total_lookups));
    }

    pub fn getStats(self: *const TranslationCache) CacheStats {
        return .{
            .total_lookups = self.total_lookups,
            .total_hits = self.total_hits,
            .total_misses = self.total_misses,
            .hit_rate = self.getHitRate(),
        };
    }
};

pub const CacheStats = struct {
    total_lookups: u64,
    total_hits: u64,
    total_misses: u64,
    hit_rate: f64,
};
