// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/vad.zig
// Purpose: Virtual Address Descriptor 表（有序槽位）— Reserve/Commit 元数据，供 `NtQueryVirtualMemory` 与惰性提交。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-memory_basic_information

const std = @import("std");

/// 常规用户/内核页大小（当前目标均为 4KiB，与 `arch` 分页一致）。
/// 内联常量以便 `zig test src/mm/vad.zig` 不依赖 `arch` 模块路径。
const page_size_bytes: u64 = 4096;

pub const max_vad: usize = 384;

pub const VadState = enum(u8) {
    reserved = 0,
    committed = 1,
};

/// 与 `MEMORY_BASIC_INFORMATION.State` 对齐的常量（公开 Win32）。
pub const MEM_COMMIT: u32 = 0x1000;
pub const MEM_RESERVE: u32 = 0x2000;
pub const MEM_FREE: u32 = 0x10000;

pub const VadEntry = struct {
    start: u64,
    end_exclusive: u64,
    state: VadState,
    protect: u32,
    /// 栈底保护页：命中后由 #PF 路径尝试扩展（见 `tryExpandGuard`）。
    is_guard: bool = false,

    pub fn contains(self: *const VadEntry, va: u64) bool {
        return va >= self.start and va < self.end_exclusive;
    }
};

pub const VadTable = struct {
    entries: [max_vad]VadEntry = undefined,
    len: u16 = 0,

    pub fn clear(self: *VadTable) void {
        self.len = 0;
    }

    /// 按 `start` 升序；返回第一个 `entries[i].start > va` 的下标，或 `len`。
    fn lowerBoundStart(self: *const VadTable, va: u64) u16 {
        // `start` 严格升序；首个 `start > va` 的位置。
        var lo: u16 = 0;
        var hi: u16 = self.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries[mid].start <= va) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    /// 合并相邻且 `state`/`protect`/`is_guard` 相同的条目（插入或保护变更后调用）。
    pub fn coalesceAdjacent(self: *VadTable) void {
        if (self.len <= 1) return;
        var out: u16 = 0;
        var r: u16 = 1;
        while (r < self.len) : (r += 1) {
            const left = &self.entries[out];
            const right = self.entries[r];
            if (left.end_exclusive == right.start and
                left.state == right.state and
                left.protect == right.protect and
                left.is_guard == right.is_guard)
            {
                left.end_exclusive = right.end_exclusive;
            } else {
                out += 1;
                self.entries[out] = right;
            }
        }
        self.len = out + 1;
    }

    fn overlaps(a0: u64, a1: u64, b0: u64, b1: u64) bool {
        return !(a1 <= b0 or b1 <= a0);
    }

    /// 按 `start` 升序插入；与现有区间重叠则失败。
    pub fn insert(self: *VadTable, start: u64, end_exclusive: u64, state: VadState, protect: u32, is_guard: bool) bool {
        if (start >= end_exclusive) return false;
        if (self.len >= max_vad) return false;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const e = self.entries[i];
            if (overlaps(start, end_exclusive, e.start, e.end_exclusive)) return false;
        }
        const slot: u16 = self.lowerBoundStart(start);
        var s: u16 = self.len;
        while (s > slot) : (s -= 1) {
            self.entries[s] = self.entries[s - 1];
        }
        self.entries[slot] = .{
            .start = start,
            .end_exclusive = end_exclusive,
            .state = state,
            .protect = protect,
            .is_guard = is_guard,
        };
        self.len += 1;
        self.coalesceAdjacent();
        return true;
    }

    /// 移除与 `[start, start+num_pages*ps)` 完全相等的条目（精确匹配单条 VAD）。
    pub fn removeExact(self: *VadTable, start: u64, num_pages: u32) bool {
        const ps: u64 = page_size_bytes;
        const end = start + @as(u64, num_pages) * ps;
        var i: u16 = 0;
        while (i < self.len) : (i += 1) {
            const e = self.entries[i];
            if (e.start == start and e.end_exclusive == end) {
                const last = self.len - 1;
                self.entries[i] = self.entries[last];
                self.len -= 1;
                return true;
            }
        }
        return false;
    }

    /// 若某 VAD 以 `range_start` 为起点且覆盖至少 `range_end_exclusive`，则删去前缀 `[range_start, range_end_exclusive)`，
    /// 保留右侧（用于 `MEM_RELEASE` / unmap 与 VAD 对齐）。
    pub fn removePrefixRange(self: *VadTable, range_start: u64, range_end_exclusive: u64) bool {
        if (range_start >= range_end_exclusive) return false;
        var i: u16 = 0;
        while (i < self.len) : (i += 1) {
            const e = self.entries[i];
            if (e.start == range_start and e.end_exclusive >= range_end_exclusive) {
                if (e.end_exclusive == range_end_exclusive) {
                    self.removeAt(i);
                    return true;
                }
                self.entries[i].start = range_end_exclusive;
                return true;
            }
        }
        return false;
    }

    /// 将已提交区内 `[range_start, range_end_exclusive)` 标回 **reserved**（`MEM_DECOMMIT` 元数据；调用方负责 unmap PTE）。
    pub fn decommitSubrange(self: *VadTable, range_start: u64, range_end_exclusive: u64, no_access_protect: u32) bool {
        if (range_start >= range_end_exclusive) return false;
        var cur = range_start;
        while (cur < range_end_exclusive) {
            const e = self.findContaining(cur) orelse return false;
            if (e.state != .committed) return false;
            const seg_end = @min(range_end_exclusive, e.end_exclusive);
            if (!self.replaceRangeProtect(cur, seg_end, no_access_protect)) return false;
            // 将刚写入的中间段改回 reserved（replaceRangeProtect 拆条后需按区间找条目）
            var j: u16 = 0;
            while (j < self.len) : (j += 1) {
                if (self.entries[j].start == cur and self.entries[j].end_exclusive == seg_end) {
                    self.entries[j].state = .reserved;
                    self.entries[j].protect = no_access_protect;
                    self.entries[j].is_guard = false;
                    break;
                }
            }
            cur = seg_end;
        }
        self.coalesceAdjacent();
        return true;
    }

    /// 查找包含 `va` 的 VAD（任意状态）；表按 `start` 有序。
    pub fn findContaining(self: *const VadTable, va: u64) ?VadEntry {
        if (self.len == 0) return null;
        const lb = self.lowerBoundStart(va);
        const i = if (lb > 0) lb - 1 else 0;
        if (self.entries[i].contains(va)) return self.entries[i];
        return null;
    }

    /// 查找包含 `va` 且仍为 reserved 的条目（可惰性提交）。
    /// 跨多条 VAD 的 `NtProtectVirtualMemory`：自 `range_start` 起逐段调用 `replaceRangeProtect`。
    pub fn replaceSpanProtect(self: *VadTable, range_start: u64, range_end_exclusive: u64, new_protect: u32) bool {
        var cur = range_start;
        while (cur < range_end_exclusive) {
            const e = self.findContaining(cur) orelse return false;
            const seg_end = @min(range_end_exclusive, e.end_exclusive);
            if (!self.replaceRangeProtect(cur, seg_end, new_protect)) return false;
            cur = seg_end;
        }
        self.coalesceAdjacent();
        return true;
    }

    pub fn findReservedContaining(self: *const VadTable, va: u64) ?VadEntry {
        const e = self.findContaining(va) orelse return null;
        if (e.state != .reserved) return null;
        return e;
    }

    /// 将覆盖 `va` 的 reserved VAD 整条标为 committed（在调用方已映射全部页或采用全区提交策略时使用）。
    pub fn markCommittedRange(self: *VadTable, start: u64, end_exclusive: u64) void {
        var i: u16 = 0;
        while (i < self.len) : (i += 1) {
            if (self.entries[i].start == start and self.entries[i].end_exclusive == end_exclusive) {
                self.entries[i].state = .committed;
                return;
            }
        }
    }

    /// 将 `va` 所在 reserved 区升级为 committed（单条 VAD 整体）。
    pub fn upgradeReservedContaining(self: *VadTable, va: u64) void {
        var i: u16 = 0;
        while (i < self.len) : (i += 1) {
            if (self.entries[i].contains(va) and self.entries[i].state == .reserved) {
                self.entries[i].state = .committed;
                return;
            }
        }
    }

    fn removeAt(self: *VadTable, idx: u16) void {
        if (self.len == 0) return;
        const last = self.len - 1;
        self.entries[idx] = self.entries[last];
        self.len -= 1;
    }

    /// `NtProtectVirtualMemory` 后同步 VAD：唯一覆盖 `[range_start, range_end_exclusive)` 的条目更新 `protect`；
    /// 若为真子区间则拆成至多 3 条（拆分后 `is_guard` 清零，与栈 guard 细化为后续项）。
    pub fn replaceRangeProtect(self: *VadTable, range_start: u64, range_end_exclusive: u64, new_protect: u32) bool {
        if (range_start >= range_end_exclusive) return false;
        var i: u16 = 0;
        while (i < self.len) : (i += 1) {
            const e = self.entries[i];
            if (e.start <= range_start and e.end_exclusive >= range_end_exclusive) {
                if (e.start == range_start and e.end_exclusive == range_end_exclusive) {
                    self.entries[i].protect = new_protect;
                    self.coalesceAdjacent();
                    return true;
                }
                var pieces: u8 = 1;
                if (e.start < range_start) pieces += 1;
                if (range_end_exclusive < e.end_exclusive) pieces += 1;
                if (@as(usize, self.len) - 1 + @as(usize, pieces) > max_vad) return false;

                self.removeAt(i);

                if (e.start < range_start) {
                    if (!self.insert(e.start, range_start, e.state, e.protect, false)) return false;
                }
                if (!self.insert(range_start, range_end_exclusive, e.state, new_protect, false)) return false;
                if (range_end_exclusive < e.end_exclusive) {
                    if (!self.insert(range_end_exclusive, e.end_exclusive, e.state, e.protect, false)) return false;
                }
                self.coalesceAdjacent();
                return true;
            }
        }
        return false;
    }
};

test "vad insert sorted no overlap" {
    var t: VadTable = .{};
    try std.testing.expect(t.insert(0x4000, 0x5000, .reserved, 0x04, false));
    try std.testing.expect(t.insert(0x2000, 0x3000, .reserved, 0x04, false));
    try std.testing.expectEqual(@as(u16, 2), t.len);
    try std.testing.expectEqual(@as(u64, 0x2000), t.entries[0].start);
    try std.testing.expectEqual(@as(u64, 0x4000), t.entries[1].start);
    try std.testing.expect(!t.insert(0x2500, 0x4500, .reserved, 0x04, false));
}

test "vad replaceRangeProtect exact" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    try std.testing.expect(t.insert(0x20000, 0x20000 + ps, .committed, 0x04, false));
    try std.testing.expect(t.replaceRangeProtect(0x20000, 0x20000 + ps, 0x02));
    try std.testing.expectEqual(@as(u16, 1), t.len);
    try std.testing.expectEqual(@as(u32, 0x02), t.entries[0].protect);
}

test "vad replaceRangeProtect splits three pieces" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    try std.testing.expect(t.insert(0x10000, 0x10000 + 5 * ps, .committed, 0x04, false));
    try std.testing.expect(t.replaceRangeProtect(0x10000 + ps, 0x10000 + 4 * ps, 0x02));
    try std.testing.expectEqual(@as(u16, 3), t.len);
    try std.testing.expectEqual(@as(u32, 0x04), t.findContaining(0x10000).?.protect);
    try std.testing.expectEqual(@as(u32, 0x02), t.findContaining(0x10000 + 2 * ps).?.protect);
    try std.testing.expectEqual(@as(u32, 0x04), t.findContaining(0x10000 + 4 * ps).?.protect);
}

test "vad find and remove exact" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    _ = t.insert(0x10000, 0x10000 + 3 * ps, .reserved, 0x04, false);
    try std.testing.expect(t.findContaining(0x11000) != null);
    try std.testing.expect(t.removeExact(0x10000, 3));
    try std.testing.expectEqual(@as(u16, 0), t.len);
}

test "vad findContaining gap returns null" {
    var t: VadTable = .{};
    try std.testing.expect(t.insert(0x1000, 0x2000, .committed, 0x04, false));
    try std.testing.expect(t.insert(0x3000, 0x4000, .committed, 0x04, false));
    try std.testing.expect(t.findContaining(0x2500) == null);
}

test "vad replaceSpanProtect two adjacent" {
    var t: VadTable = .{};
    try std.testing.expect(t.insert(0x1000, 0x2000, .committed, 0x04, false));
    try std.testing.expect(t.insert(0x2000, 0x3000, .committed, 0x04, false));
    try std.testing.expect(t.replaceSpanProtect(0x1000, 0x3000, 0x02));
    try std.testing.expectEqual(@as(u32, 0x02), t.findContaining(0x1500).?.protect);
}

test "vad coalesce after insert" {
    var t: VadTable = .{};
    try std.testing.expect(t.insert(0x1000, 0x2000, .committed, 0x04, false));
    try std.testing.expect(t.insert(0x2000, 0x3000, .committed, 0x04, false));
    try std.testing.expectEqual(@as(u16, 1), t.len);
    try std.testing.expectEqual(0x3000, t.entries[0].end_exclusive);
}

test "vad decommitSubrange" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    try std.testing.expect(t.insert(0x1000, 0x5000, .committed, 0x04, false)); // 4 pages
    try std.testing.expect(t.decommitSubrange(0x1000 + ps, 0x1000 + 3 * ps, 0x01));
    try std.testing.expectEqual(VadState.reserved, t.findContaining(0x2000).?.state);
}
