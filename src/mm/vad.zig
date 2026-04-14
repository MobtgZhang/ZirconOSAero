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
// Module: src/mm/vad.zig
// Purpose: 虚拟地址描述符 **AVL 树**（按 `start` 键）— Reserve/Commit、`NtQueryVirtualMemory`、惰性提交与保护拆分。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-memory_basic_information
// AVL: textbook insertion/deletion with subtree heights (Cormen et al. style, clean-room).

const std = @import("std");

const page_size_bytes: u64 = 4096;

/// AVL 节点上限；受 `AddressSpace` 总大小约束（见 `ps/process.zig` 静态断言）。
/// 提升到 4096 以支持更大的地址空间和更多的内存区域，符合 NT6.1 实际需求。
/// 若将来 AddressSpace 采用堆分配 VadTable，可再进一步提升。
pub const max_vad: usize = 4096;
const MAX_NODES: usize = max_vad;
const NULL_IDX: u16 = 0;

pub const VadState = enum(u8) {
    reserved = 0,
    committed = 1,
    /// 单个 VAD 内同时存在 committed 和 reserved 子区域。
    /// `upgradeReservedContaining` 将 reserved VAD 拆分为最多 3 个子 VAD。
    partially_committed = 2,
};

pub const MEM_COMMIT: u32 = 0x1000;
pub const MEM_RESERVE: u32 = 0x2000;
pub const MEM_FREE: u32 = 0x10000;

pub const VadEntry = struct {
    start: u64,
    end_exclusive: u64,
    state: VadState,
    protect: u32,
    is_guard: bool = false,

    pub fn contains(self: *const VadEntry, va: u64) bool {
        return va >= self.start and va < self.end_exclusive;
    }
};

const TreeNode = struct {
    start: u64,
    end_exclusive: u64,
    state: VadState,
    protect: u32,
    is_guard: bool,
    left: u16 = NULL_IDX,
    right: u16 = NULL_IDX,
    height: u8 = 1,
};

fn nodeHeight(t: *const VadTable, i: u16) i32 {
    if (i == NULL_IDX) return 0;
    return t.nodes[i].height;
}

fn maxInt(a: i32, b: i32) i32 {
    return @max(a, b);
}

fn updateHeight(t: *VadTable, i: u16) void {
    const l = t.nodes[i].left;
    const r = t.nodes[i].right;
    const lh = nodeHeight(t, l);
    const rh = nodeHeight(t, r);
    t.nodes[i].height = @as(u8, @intCast(1 + maxInt(lh, rh)));
}

fn balanceFactor(t: *const VadTable, i: u16) i32 {
    return nodeHeight(t, t.nodes[i].left) - nodeHeight(t, t.nodes[i].right);
}

fn rotateRight(t: *VadTable, y: u16) u16 {
    const x = t.nodes[y].left;
    const t2 = t.nodes[x].right;
    t.nodes[x].right = y;
    t.nodes[y].left = t2;
    updateHeight(t, y);
    updateHeight(t, x);
    return x;
}

fn rotateLeft(t: *VadTable, x: u16) u16 {
    const y = t.nodes[x].right;
    const t2 = t.nodes[y].left;
    t.nodes[y].left = x;
    t.nodes[x].right = t2;
    updateHeight(t, x);
    updateHeight(t, y);
    return y;
}

fn rebalance(t: *VadTable, n: u16) u16 {
    updateHeight(t, n);
    const cur = n;
    const bf = balanceFactor(t, cur);
    if (bf > 1 and balanceFactor(t, t.nodes[cur].left) >= 0) {
        return rotateRight(t, cur);
    }
    if (bf > 1 and balanceFactor(t, t.nodes[cur].left) < 0) {
        t.nodes[cur].left = rotateLeft(t, t.nodes[cur].left);
        return rotateRight(t, cur);
    }
    if (bf < -1 and balanceFactor(t, t.nodes[cur].right) <= 0) {
        return rotateLeft(t, cur);
    }
    if (bf < -1 and balanceFactor(t, t.nodes[cur].right) > 0) {
        t.nodes[cur].right = rotateRight(t, t.nodes[cur].right);
        return rotateLeft(t, cur);
    }
    return cur;
}

pub const VadTable = struct {
    root: u16 = NULL_IDX,
    nodes: [MAX_NODES + 1]TreeNode = undefined,
    free_stack: [MAX_NODES]u16 = undefined,
    free_top: u16 = 0,
    next_slot: u16 = 1,
    node_count: u16 = 0,

    pub fn len(self: *const VadTable) u16 {
        return self.node_count;
    }

    pub fn clear(self: *VadTable) void {
        self.root = NULL_IDX;
        self.free_top = 0;
        self.next_slot = 1;
        self.node_count = 0;
    }

    /// 地址空间创建时显式调用（与 `vm.initAddressSpaceInPlace` 配套）；等价于 `clear`，语义上表示「空树」而非中途清空。
    pub fn initEmpty(self: *VadTable) void {
        self.clear();
    }

    fn allocIndex(self: *VadTable) ?u16 {
        if (self.free_top > 0) {
            self.free_top -= 1;
            return self.free_stack[self.free_top];
        }
        if (self.next_slot > MAX_NODES) return null;
        const i = self.next_slot;
        self.next_slot += 1;
        return i;
    }

    fn freeIndex(self: *VadTable, i: u16) void {
        if (i == NULL_IDX) return;
        std.debug.assert(self.free_top < MAX_NODES);
        self.free_stack[self.free_top] = i;
        self.free_top += 1;
        self.nodes[i] = .{
            .start = 0,
            .end_exclusive = 0,
            .state = .reserved,
            .protect = 0,
            .is_guard = false,
            .left = NULL_IDX,
            .right = NULL_IDX,
            .height = 1,
        };
    }

    fn toEntry(n: TreeNode) VadEntry {
        return .{
            .start = n.start,
            .end_exclusive = n.end_exclusive,
            .state = n.state,
            .protect = n.protect,
            .is_guard = n.is_guard,
        };
    }

    fn intervalsOverlap(a0: u64, a1: u64, b0: u64, b1: u64) bool {
        return !(a1 <= b0 or b1 <= a0);
    }

    /// 最大 `start` 且 `start <= key` 的节点下标；无则 NULL_IDX。
    fn floorIndex(self: *const VadTable, key: u64) u16 {
        var cur = self.root;
        var cand: u16 = NULL_IDX;
        while (cur != NULL_IDX) {
            if (self.nodes[cur].start <= key) {
                cand = cur;
                cur = self.nodes[cur].right;
            } else {
                cur = self.nodes[cur].left;
            }
        }
        return cand;
    }

    /// 最小 `start` 且 `start >= key` 的节点下标。
    fn ceilIndex(self: *const VadTable, key: u64) u16 {
        var cur = self.root;
        var cand: u16 = NULL_IDX;
        while (cur != NULL_IDX) {
            if (self.nodes[cur].start >= key) {
                cand = cur;
                cur = self.nodes[cur].left;
            } else {
                cur = self.nodes[cur].right;
            }
        }
        return cand;
    }

    fn findByStart(self: *const VadTable, start: u64) ?u16 {
        var cur = self.root;
        while (cur != NULL_IDX) {
            if (self.nodes[cur].start == start) return cur;
            if (start < self.nodes[cur].start) {
                cur = self.nodes[cur].left;
            } else {
                cur = self.nodes[cur].right;
            }
        }
        return null;
    }

    pub fn findContaining(self: *const VadTable, va: u64) ?VadEntry {
        const fi = self.floorIndex(va);
        if (fi == NULL_IDX) return null;
        const n = self.nodes[fi];
        if (va >= n.start and va < n.end_exclusive) return toEntry(n);
        return null;
    }

    /// 区间 `[s,e)` 是否与现有 VAD 相交（插入前检查）。
    pub fn wouldOverlap(self: *const VadTable, s: u64, e: u64) bool {
        const f = self.floorIndex(s);
        if (f != NULL_IDX) {
            const n = self.nodes[f];
            if (intervalsOverlap(s, e, n.start, n.end_exclusive)) return true;
        }
        const c = self.ceilIndex(s);
        if (c != NULL_IDX) {
            const n = self.nodes[c];
            if (intervalsOverlap(s, e, n.start, n.end_exclusive)) return true;
        }
        return false;
    }

    fn insertRec(self: *VadTable, root: u16, start: u64, end_exclusive: u64, state: VadState, protect: u32, is_guard: bool) ?u16 {
        if (root == NULL_IDX) {
            const ni = self.allocIndex() orelse return null;
            self.nodes[ni] = .{
                .start = start,
                .end_exclusive = end_exclusive,
                .state = state,
                .protect = protect,
                .is_guard = is_guard,
                .left = NULL_IDX,
                .right = NULL_IDX,
                .height = 1,
            };
            self.node_count += 1;
            return ni;
        }
        if (start < self.nodes[root].start) {
            const nl = self.insertRec(self.nodes[root].left, start, end_exclusive, state, protect, is_guard) orelse return null;
            self.nodes[root].left = nl;
        } else if (start > self.nodes[root].start) {
            const nr = self.insertRec(self.nodes[root].right, start, end_exclusive, state, protect, is_guard) orelse return null;
            self.nodes[root].right = nr;
        } else {
            return null;
        }
        return rebalance(self, root);
    }

    /// `coalesce_tail`：为 false 时不在末尾调用 `coalesceAdjacent`（供 `coalesceAdjacent` 重建树，避免无限递归）。
    pub fn insert(self: *VadTable, start: u64, end_exclusive: u64, state: VadState, protect: u32, is_guard: bool) bool {
        return self.insertEx(start, end_exclusive, state, protect, is_guard, true);
    }

    fn insertEx(self: *VadTable, start: u64, end_exclusive: u64, state: VadState, protect: u32, is_guard: bool, coalesce_tail: bool) bool {
        if (start >= end_exclusive) return false;
        if (self.wouldOverlap(start, end_exclusive)) return false;
        const nr = self.insertRec(self.root, start, end_exclusive, state, protect, is_guard) orelse return false;
        self.root = nr;
        if (coalesce_tail) self.coalesceAdjacent();
        return true;
    }

    fn minStartNode(self: *const VadTable, n: u16) u16 {
        var cur: u16 = n;
        while (self.nodes[cur].left != NULL_IDX) {
            cur = self.nodes[cur].left;
        }
        return cur;
    }

    fn deleteRec(self: *VadTable, root: u16, start_key: u64) struct { root: u16, found: bool } {
        if (root == NULL_IDX) return .{ .root = NULL_IDX, .found = false };
        if (start_key < self.nodes[root].start) {
            const sub = self.deleteRec(self.nodes[root].left, start_key);
            if (!sub.found) return .{ .root = root, .found = false };
            self.nodes[root].left = sub.root;
            return .{ .root = rebalance(self, root), .found = true };
        }
        if (start_key > self.nodes[root].start) {
            const sub = self.deleteRec(self.nodes[root].right, start_key);
            if (!sub.found) return .{ .root = root, .found = false };
            self.nodes[root].right = sub.root;
            return .{ .root = rebalance(self, root), .found = true };
        }
        if (self.nodes[root].left == NULL_IDX or self.nodes[root].right == NULL_IDX) {
            const tmp = if (self.nodes[root].left != NULL_IDX) self.nodes[root].left else self.nodes[root].right;
            self.freeIndex(root);
            self.node_count -= 1;
            return .{ .root = tmp, .found = true };
        }
        const succ = self.minStartNode(self.nodes[root].right);
        self.nodes[root].start = self.nodes[succ].start;
        self.nodes[root].end_exclusive = self.nodes[succ].end_exclusive;
        self.nodes[root].state = self.nodes[succ].state;
        self.nodes[root].protect = self.nodes[succ].protect;
        self.nodes[root].is_guard = self.nodes[succ].is_guard;
        const sub = self.deleteRec(self.nodes[root].right, self.nodes[succ].start);
        self.nodes[root].right = sub.root;
        return .{ .root = rebalance(self, root), .found = true };
    }

    pub fn deleteByStart(self: *VadTable, start: u64) bool {
        const r = self.deleteRec(self.root, start);
        if (!r.found) return false;
        self.root = r.root;
        return true;
    }

    /// 中序导出 VAD 节点（只读遍历）；供 fork 复制等路径使用。
    pub fn collectEntriesInorder(self: *const VadTable, out: []VadEntry) usize {
        var stack: [MAX_NODES]u16 = undefined;
        var sp: usize = 0;
        var cur = self.root;
        var w: usize = 0;
        while (sp > 0 or cur != NULL_IDX) {
            while (cur != NULL_IDX) {
                stack[sp] = cur;
                sp += 1;
                cur = self.nodes[cur].left;
            }
            sp -= 1;
            cur = stack[sp];
            if (w < out.len) {
                out[w] = toEntry(self.nodes[cur]);
                w += 1;
            }
            cur = self.nodes[cur].right;
        }
        return w;
    }

    /// 事务性合并相邻同属性 VAD。
    /// - 失败时保持原树不变（原子性）。
    /// - `coalesce_tail=false` 时由 `insertEx` 调用，避免递归合并。
    pub fn coalesceAdjacent(self: *VadTable) void {
        if (self.node_count <= 1) return;
        var tmp: [MAX_NODES]VadEntry = undefined;
        const n = self.collectEntriesInorder(&tmp);
        if (n <= 1) return;

        var out: usize = 0;
        var r: usize = 1;
        while (r < n) : (r += 1) {
            const left = &tmp[out];
            const right = tmp[r];
            if (left.end_exclusive == right.start and
                left.state == right.state and
                left.protect == right.protect and
                left.is_guard == right.is_guard)
            {
                left.end_exclusive = right.end_exclusive;
            } else {
                out += 1;
                tmp[out] = right;
            }
        }
        const new_len = out + 1;

        // 事务性重建：先收集所有节点索引，再一起删除，最后插入
        var to_delete: [MAX_NODES]u64 = undefined;
        var del_count: usize = 0;
        {
            var stack: [MAX_NODES]u16 = undefined;
            var sp: usize = 0;
            var cur = self.root;
            while (sp > 0 or cur != NULL_IDX) {
                while (cur != NULL_IDX) {
                    stack[sp] = cur;
                    sp += 1;
                    cur = self.nodes[cur].left;
                }
                sp -= 1;
                cur = stack[sp];
                if (del_count < MAX_NODES) {
                    to_delete[del_count] = self.nodes[cur].start;
                    del_count += 1;
                }
                cur = self.nodes[cur].right;
            }
        }

        // 全部删除
        var i: usize = 0;
        while (i < del_count) : (i += 1) {
            _ = self.deleteByStart(to_delete[i]);
        }

        // 全部重新插入（失败时维持空树状态）
        i = 0;
        while (i < new_len) : (i += 1) {
            const e = tmp[i];
            if (!self.insertEx(e.start, e.end_exclusive, e.state, e.protect, e.is_guard, false)) {
                // 插入失败，恢复空树状态
                self.clear();
                return;
            }
        }
    }

    /// 精确删除 VAD（start 和 end 均匹配）。若需处理中间删除，应使用 removePrefixRange。
    pub fn removeExact(self: *VadTable, start: u64, num_pages: u32) bool {
        const ps: u64 = page_size_bytes;
        const end = start + @as(u64, num_pages) * ps;
        const i = self.findByStart(start) orelse return false;
        const n = self.nodes[i];
        if (n.start == start and n.end_exclusive == end) {
            // 删除整个节点
            if (!self.deleteByStart(n.start)) return false;
            return true;
        }
        // 节点存在但范围不匹配，尝试中间删除
        if (n.start < start and n.end_exclusive > end) {
            // 中间删除：拆分为 [n.start, start) + [end, n.end_exclusive)
            // 必须使用 n.start 进行删除
            if (!self.deleteByStart(n.start)) return false;
            // 先插入前半部分（失败时只丢失前半）
            _ = self.insertEx(n.start, start, n.state, n.protect, n.is_guard, false);
            // 再插入后半部分
            if (!self.insertEx(end, n.end_exclusive, n.state, n.protect, n.is_guard, true)) {
                // 后半部分插入失败，前半部分丢失，但至少后半部分保留了
                return false;
            }
            return true;
        }
        return false;
    }

    /// 按前缀范围删除：删除 [range_start, range_end_exclusive)。
    /// 若 range_start 在某 VAD 内部，自动拆分并保留后半部分。
    pub fn removePrefixRange(self: *VadTable, range_start: u64, range_end_exclusive: u64) bool {
        if (range_start >= range_end_exclusive) return false;
        const i = self.findByStart(range_start) orelse return false;
        const n = self.nodes[i];
        if (n.start == range_start and n.end_exclusive >= range_end_exclusive) {
            if (n.end_exclusive == range_end_exclusive) {
                return self.deleteByStart(range_start);
            }
            // 范围匹配但需保留后半部分：拆分后删除前缀
            const ns = range_end_exclusive;
            const ne = n.end_exclusive;
            const st = n.state;
            const pr = n.protect;
            const ig = n.is_guard;
            if (!self.deleteByStart(range_start)) return false;
            return self.insertEx(ns, ne, st, pr, ig, true);
        }
        // range_start 不在节点起始处
        if (n.start < range_start) {
            if (n.end_exclusive <= range_end_exclusive) {
                // 节点完全在删除范围内：删除包含前半部分的节点
                // 先插入后半部分（如有），再删除原节点
                const old_end = n.end_exclusive;
                if (old_end > range_end_exclusive) {
                    // 节点延伸到删除范围外，保留后半部分
                    const st = n.state;
                    const pr = n.protect;
                    const ig = n.is_guard;
                    if (!self.deleteByStart(n.start)) return false;
                    // 插入后半部分
                    if (!self.insertEx(range_end_exclusive, old_end, st, pr, ig, true)) return false;
                    return true;
                }
                // 节点完全在删除范围内
                return self.deleteByStart(n.start);
            }
            // 中间删除：拆分为 [n.start, range_start) + [range_end_exclusive, n.end_exclusive)
            const old_start = n.start;
            const old_end = n.end_exclusive;
            const st = n.state;
            const pr = n.protect;
            const ig = n.is_guard;
            if (!self.deleteByStart(n.start)) return false;
            // 先插入前半部分（失败时只丢失前半，保持后半）
            _ = self.insertEx(old_start, range_start, st, pr, ig, false);
            // 再插入后半部分
            return self.insertEx(range_end_exclusive, old_end, st, pr, ig, true);
        }
        return false;
    }

    pub fn decommitSubrange(self: *VadTable, range_start: u64, range_end_exclusive: u64, no_access_protect: u32) bool {
        if (range_start >= range_end_exclusive) return false;
        var cur = range_start;
        while (cur < range_end_exclusive) {
            const e = self.findContaining(cur) orelse return false;
            if (e.state != .committed) return false;
            const seg_end = @min(range_end_exclusive, e.end_exclusive);
            if (!self.replaceRangeProtect(cur, seg_end, no_access_protect)) return false;
            const j = self.findByStart(cur) orelse return false;
            if (self.nodes[j].start == cur and self.nodes[j].end_exclusive == seg_end) {
                self.nodes[j].state = .reserved;
                self.nodes[j].protect = no_access_protect;
                self.nodes[j].is_guard = false;
            }
            cur = seg_end;
        }
        self.coalesceAdjacent();
        return true;
    }

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

    pub fn markCommittedRange(self: *VadTable, start: u64, end_exclusive: u64) void {
        const i = self.findByStart(start) orelse return;
        if (self.nodes[i].end_exclusive == end_exclusive) {
            self.nodes[i].state = .committed;
        }
    }

    /// 将 VA 所在的 reserved VAD 拆分为最多 3 个子 VAD：
    /// - `[start, page_start)` —— reserved（前半）
    /// - `[page_start, page_end)` —— committed（故障页，已由 `mapPageAlloc` 提交）
    /// - `[page_end, end_exclusive)` —— reserved（后半；前半/后半为空时省略相应 VAD）
    /// 事务性操作：失败时保持原树不变。
    pub fn upgradeReservedContaining(self: *VadTable, va: u64) void {
        const page = (va / page_size_bytes) * page_size_bytes;
        const page_end = page + page_size_bytes;
        const i = self.floorIndex(va);
        if (i == NULL_IDX) return;
        const n = self.nodes[i];
        if (va < n.start or va >= n.end_exclusive or n.state != .reserved) return;

        // 保留原始值用于拆分
        const old_start = n.start;
        const old_end = n.end_exclusive;
        const old_prot = n.protect;

        // 先收集需要插入的子段
        var pieces: u8 = 0;
        if (old_start < page) pieces += 1;
        if (page < old_end) pieces += 1;
        if (page_end < old_end) pieces += 1;

        // 检查空间是否足够
        if (@as(usize, self.node_count) - 1 + @as(usize, pieces) > MAX_NODES) return;

        // 事务性操作：先收集所有子段，验证后再执行删除和插入
        var segments: [3]struct { start: u64, end_exclusive: u64, state: VadState, protect: u32, is_guard: bool } = undefined;
        var seg_count: u8 = 0;

        if (old_start < page) {
            segments[seg_count] = .{ .start = old_start, .end_exclusive = page, .state = .reserved, .protect = old_prot, .is_guard = false };
            seg_count += 1;
        }
        if (page < old_end) {
            segments[seg_count] = .{ .start = page, .end_exclusive = @min(page_end, old_end), .state = .committed, .protect = old_prot, .is_guard = false };
            seg_count += 1;
        }
        if (page_end < old_end) {
            segments[seg_count] = .{ .start = page_end, .end_exclusive = old_end, .state = .reserved, .protect = old_prot, .is_guard = false };
            seg_count += 1;
        }

        // 删除原节点
        if (!self.deleteByStart(old_start)) return;

        // 重新插入所有子段（失败时回滚）
        var j: u8 = 0;
        while (j < seg_count) : (j += 1) {
            const seg = segments[j];
            if (!self.insertEx(seg.start, seg.end_exclusive, seg.state, seg.protect, seg.is_guard, false)) {
                // 插入失败，回滚：重新插入原节点
                _ = self.insertEx(old_start, old_end, .reserved, old_prot, false, true);
                return;
            }
        }

        // 尝试合并相邻同属性 VAD
        self.coalesceAdjacent();
    }

    pub fn replaceRangeProtect(self: *VadTable, range_start: u64, range_end_exclusive: u64, new_protect: u32) bool {
        if (range_start >= range_end_exclusive) return false;
        const i = self.floorIndex(range_start);
        if (i == NULL_IDX) return false;
        const e = self.nodes[i];
        if (range_start < e.start or range_end_exclusive > e.end_exclusive) return false;
        if (e.start == range_start and e.end_exclusive == range_end_exclusive) {
            self.nodes[i].protect = new_protect;
            self.nodes[i].is_guard = false;
            self.coalesceAdjacent();
            return true;
        }
        var pieces: u8 = 1;
        if (e.start < range_start) pieces += 1;
        if (range_end_exclusive < e.end_exclusive) pieces += 1;
        if (@as(usize, self.node_count) - 1 + @as(usize, pieces) > MAX_NODES) return false;

        const old_start = e.start;
        const old_end = e.end_exclusive;
        const old_state = e.state;
        const old_prot = e.protect;
        _ = self.deleteByStart(old_start);

        if (old_start < range_start) {
            if (!self.insert(old_start, range_start, old_state, old_prot, false)) return false;
        }
        if (!self.insert(range_start, range_end_exclusive, old_state, new_protect, false)) return false;
        if (range_end_exclusive < old_end) {
            if (!self.insert(range_end_exclusive, old_end, old_state, old_prot, false)) return false;
        }
        self.coalesceAdjacent();
        return true;
    }
};

test "vad insert sorted no overlap" {
    var t: VadTable = .{};
    try std.testing.expect(t.insert(0x4000, 0x5000, .reserved, 0x04, false));
    try std.testing.expect(t.insert(0x2000, 0x3000, .reserved, 0x04, false));
    try std.testing.expectEqual(@as(u16, 2), t.len());
    try std.testing.expect(!t.insert(0x2500, 0x4500, .reserved, 0x04, false));
}

test "vad replaceRangeProtect exact" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    try std.testing.expect(t.insert(0x20000, 0x20000 + ps, .committed, 0x04, false));
    try std.testing.expect(t.replaceRangeProtect(0x20000, 0x20000 + ps, 0x02));
    try std.testing.expectEqual(@as(u16, 1), t.len());
    try std.testing.expectEqual(@as(u32, 0x02), t.findContaining(0x20000).?.protect);
}

test "vad replaceRangeProtect splits three pieces" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    try std.testing.expect(t.insert(0x10000, 0x10000 + 5 * ps, .committed, 0x04, false));
    try std.testing.expect(t.replaceRangeProtect(0x10000 + ps, 0x10000 + 4 * ps, 0x02));
    try std.testing.expectEqual(@as(u16, 3), t.len());
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
    try std.testing.expectEqual(@as(u16, 0), t.len());
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
    try std.testing.expectEqual(@as(u16, 1), t.len());
    try std.testing.expectEqual(@as(u64, 0x3000), t.findContaining(0x1000).?.end_exclusive);
}

test "vad decommitSubrange" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    try std.testing.expect(t.insert(0x1000, 0x5000, .committed, 0x04, false));
    try std.testing.expect(t.decommitSubrange(0x1000 + ps, 0x1000 + 3 * ps, 0x01));
    try std.testing.expectEqual(VadState.reserved, t.findContaining(0x2000).?.state);
}

test "vad upgradeReservedContaining splits into two pieces" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    // reserve 两页：第二页被 commit
    try std.testing.expect(t.insert(0x1000, 0x1000 + 2 * ps, .reserved, 0x04, false));
    try std.testing.expectEqual(@as(u16, 1), t.len());
    t.upgradeReservedContaining(0x1000 + ps);
    try std.testing.expectEqual(@as(u16, 2), t.len());
    const first = t.findContaining(0x1000).?;
    try std.testing.expectEqual(VadState.reserved, first.state);
    try std.testing.expectEqual(@as(u64, 0x1000), first.start);
    try std.testing.expectEqual(@as(u64, 0x1000 + ps), first.end_exclusive);
    const second = t.findContaining(0x1000 + ps).?;
    try std.testing.expectEqual(VadState.committed, second.state);
    try std.testing.expectEqual(@as(u64, 0x1000 + ps), second.start);
    try std.testing.expectEqual(@as(u64, 0x1000 + 2 * ps), second.end_exclusive);
}

test "vad upgradeReservedContaining splits into three pieces" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    // reserve 三页：第二页被 commit
    try std.testing.expect(t.insert(0x1000, 0x1000 + 3 * ps, .reserved, 0x04, false));
    try std.testing.expectEqual(@as(u16, 1), t.len());
    t.upgradeReservedContaining(0x1000 + ps);
    try std.testing.expectEqual(@as(u16, 3), t.len());
    // 第一段：reserved
    const first = t.findContaining(0x1000).?;
    try std.testing.expectEqual(VadState.reserved, first.state);
    try std.testing.expectEqual(@as(u64, 0x1000), first.start);
    try std.testing.expectEqual(@as(u64, 0x1000 + ps), first.end_exclusive);
    // 第二段：committed
    const mid = t.findContaining(0x1000 + ps).?;
    try std.testing.expectEqual(VadState.committed, mid.state);
    // 第三段：reserved
    const third = t.findContaining(0x1000 + 2 * ps).?;
    try std.testing.expectEqual(VadState.reserved, third.state);
    try std.testing.expectEqual(@as(u64, 0x1000 + 2 * ps), third.start);
    try std.testing.expectEqual(@as(u64, 0x1000 + 3 * ps), third.end_exclusive);
}

test "vad upgradeReservedContaining first page" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    try std.testing.expect(t.insert(0x1000, 0x1000 + 2 * ps, .reserved, 0x04, false));
    t.upgradeReservedContaining(0x1000);
    try std.testing.expectEqual(@as(u16, 2), t.len());
    const committed = t.findContaining(0x1000).?;
    try std.testing.expectEqual(VadState.committed, committed.state);
    try std.testing.expectEqual(@as(u64, 0x1000), committed.start);
    try std.testing.expectEqual(@as(u64, 0x1000 + ps), committed.end_exclusive);
    const reserved = t.findContaining(0x1000 + ps).?;
    try std.testing.expectEqual(VadState.reserved, reserved.state);
}

test "vad upgradeReservedContaining last page" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    try std.testing.expect(t.insert(0x1000, 0x1000 + 2 * ps, .reserved, 0x04, false));
    t.upgradeReservedContaining(0x1000 + ps);
    try std.testing.expectEqual(@as(u16, 2), t.len());
    const reserved = t.findContaining(0x1000).?;
    try std.testing.expectEqual(VadState.reserved, reserved.state);
    try std.testing.expectEqual(@as(u64, 0x1000), reserved.start);
    try std.testing.expectEqual(@as(u64, 0x1000 + ps), reserved.end_exclusive);
    const committed = t.findContaining(0x1000 + ps).?;
    try std.testing.expectEqual(VadState.committed, committed.state);
}

test "vad upgradeReservedContaining skips committed" {
    var t: VadTable = .{};
    const ps: u64 = 4096;
    // already committed
    try std.testing.expect(t.insert(0x1000, 0x1000 + ps, .committed, 0x04, false));
    t.upgradeReservedContaining(0x1000);
    // no change: committed not reserved
    try std.testing.expectEqual(@as(u16, 1), t.len());
    const e = t.findContaining(0x1000).?;
    try std.testing.expectEqual(VadState.committed, e.state);
}

test "vad avl random insert delete balanced height" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const r = prng.random();
    var t: VadTable = .{};
    var inserted: [256]u64 = undefined;
    var n: usize = 0;
    var k: usize = 0;
    while (k < 200) : (k += 1) {
        const base = r.intRangeLessThan(u64, 1, 0x100000) * page_size_bytes;
        const pages = r.intRangeLessThan(u32, 1, 4);
        const end = base + @as(u64, pages) * page_size_bytes;
        if (base < end and !t.wouldOverlap(base, end)) {
            if (t.insert(base, end, .reserved, 0x04, false)) {
                if (n < inserted.len) {
                    inserted[n] = base;
                    n += 1;
                }
            }
        }
    }
    try std.testing.expect(t.len() > 0);
    if (t.root != NULL_IDX) {
        try std.testing.expect(t.nodes[t.root].height < 40);
    }
    while (n > 0) {
        n -= 1;
        _ = t.deleteByStart(inserted[n]);
    }
    try std.testing.expectEqual(@as(u16, 0), t.len());
}
