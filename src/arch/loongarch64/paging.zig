//! LoongArch64 page table
//! Uses software-managed TLB with multi-level page table
//! Page sizes: 16KB (default for QEMU virt)

const builtin = @import("builtin");
const std = @import("std");

pub const page_size: usize = 16384;
pub const page_mask: usize = page_size - 1;

/// 单张第三级表 2048×16KiB = 32MiB VA；`mapIdentity32MiBlock` 一次填充整块。
pub const identity_bulk_bytes: u64 = 2048 * page_size;

const L0_SHIFT: u6 = 36;
const L1_SHIFT: u6 = 25;
const L2_SHIFT: u6 = 14;
/// 每级 2048 项 → 索引占 **11 位**（勿用 `u9`：512..2047 会截断后与 0..511 别名，identity map 恰在 8MiB 处失败）
const INDEX_MASK: u64 = 0x7FF;

const PLV_MASK: u64 = 3 << 2;

pub const V: u64 = 1 << 0;
pub const D: u64 = 1 << 1;
pub const PLV_KERNEL: u64 = 0 << 2;
pub const PLV_USER: u64 = 3 << 2;
/// MAT[5:4]：0=SUC 强非缓存，1=CC 一致可缓存，2=WUC 弱非缓存（MMIO 常用）
pub const MAT_CC: u64 = 1 << 4;
pub const MAT_SUC: u64 = 0 << 4;
pub const MAT_WUC: u64 = 2 << 4;
pub const MAT_MASK: u64 = 3 << 4;
pub const NR: u64 = @as(u64, 1) << 61;
pub const NX: u64 = @as(u64, 1) << 62;
pub const RPLV: u64 = @as(u64, 1) << 63;

pub const Present: u64 = V;
pub const Write: u64 = D;
pub const User: u64 = PLV_USER;
pub const WriteThrough: u64 = 0;
/// 须为非零 MAT，否则 `fromFrame` 会默认加 CC；`0<<4` 无法与「未指定 MAT」区分
pub const CacheDisable: u64 = MAT_WUC;
pub const Accessed: u64 = 0;
pub const Dirty: u64 = D;
pub const LargePage: u64 = 0;
pub const Global: u64 = 0;
pub const NoExecute: u64 = NX;

const ADDR_MASK: u64 = 0x0000_FFFF_FFFF_C000;

/// 与 x86「低半区 / 高半区」概念对齐：PGD[0..1024) 为用户半区，由 `releaseUserHalfAddressSpace` 回收。
pub const user_half_l0_end_exclusive: usize = 1024;
/// `linkKernelHalfMappings` 自内核根表复制的 PGD 索引起点。
pub const kernel_linked_l0_begin: usize = user_half_l0_end_exclusive;

fn isUserLeafRaw(raw: u64) bool {
    return (raw & PLV_MASK) == PLV_USER;
}

/// `INVTLB_ALL`（op=0x0）；参见 `docs/specs/MemoryManagement_NT61_LoongArch64_NewWorld.md`。
fn invtlbAll() void {
    if (builtin.os.tag != .freestanding) return;
    asm volatile ("invtlb 0x0, $zero, $zero" ::: .{ .memory = true });
}

/// `INVTLB_ADDR_GTRUE_OR_ASID`（op=0x6），ASID=`$zero`；与 Linux `invtlb_addr(..., 0, addr)` 用法一致。
fn invtlbAddrVa(virt: u64) void {
    if (builtin.os.tag != .freestanding) return;
    asm volatile ("invtlb 0x6, $zero, %[va]"
        :
        : [va] "r" (virt),
        : .{ .memory = true });
}

/// 最近一次 `loadCr3` 写入 CSR 0x18 的根表物理地址；相等时可跳过全 TLB 刷新（单核常见：同进程连续 `activate`）。
var last_loaded_pgdl_phys: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// 当前已装载根表上的 **任意** 叶/中间项变更后须调用，以免 `loadCr3` 误判「根未变」而省略 `INVTLB_ALL`。
pub fn noteCurrentPageTablePossiblyMutated(pgd_phys: u64) void {
    if (pgd_phys == last_loaded_pgdl_phys)
        last_loaded_pgdl_phys = 0xFFFF_FFFF_FFFF_FFFF;
}

pub const PageTableEntry = packed struct(u64) {
    raw: u64 = 0,

    pub fn isPresent(self: PageTableEntry) bool {
        return (self.raw & V) != 0;
    }

    pub fn toFrame(self: PageTableEntry) u64 {
        return self.raw & ADDR_MASK;
    }

    pub fn fromFrame(frame: u64, flags: u64) PageTableEntry {
        var raw = (frame & ADDR_MASK) | flags | V | PLV_KERNEL;
        if ((raw & MAT_MASK) == 0) raw |= MAT_CC;
        return .{ .raw = raw };
    }
};

pub const PageTable = struct {
    entries: [2048]PageTableEntry,

    pub fn zero(self: *PageTable) void {
        for (&self.entries) |*e| e.* = .{};
    }
};

pub const VirtAddr = struct {
    value: u64,

    pub fn pml4Index(self: VirtAddr) u16 {
        return @truncate((self.value >> L0_SHIFT) & INDEX_MASK);
    }
    pub fn pdptIndex(self: VirtAddr) u16 {
        return @truncate((self.value >> L1_SHIFT) & INDEX_MASK);
    }
    /// 第三级页表索引（与 `ptIndex` 相同位段；仅用于与 x86 命名对齐的 API）
    pub fn pdIndex(self: VirtAddr) u16 {
        return @truncate((self.value >> L2_SHIFT) & INDEX_MASK);
    }
    pub fn ptIndex(self: VirtAddr) u16 {
        return @truncate((self.value >> L2_SHIFT) & INDEX_MASK);
    }
};

/// 遍历三级页表得到叶子物理帧 + 页内偏移（与 `mapPage`/`unmapPage` 一致）
pub fn translateVirtualToPhysical(pgd_phys: u64, virt: u64) ?u64 {
    const v = VirtAddr{ .value = virt };
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return null;
    const l1 = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1e = &l1.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return null;
    const l2 = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2e = &l2.entries[v.ptIndex()];
    if (!l2e.isPresent()) return null;
    return l2e.toFrame() | (virt & page_mask);
}

pub const AllocFrameFn = *const fn (?*anyopaque) ?u64;

/// 释放回调：`phys` 为页对齐物理地址（叶、中间表或 PGD 自身由调用方决定）。
pub const FreeFrameFn = *const fn (ctx: ?*anyopaque, phys: u64) void;

fn releaseL2All(l2_phys: u64, free_frame: FreeFrameFn, ctx: ?*anyopaque) void {
    const l2 = @as(*PageTable, @ptrFromInt(l2_phys));
    for (&l2.entries) |*e| {
        if (!e.isPresent()) continue;
        free_frame(ctx, e.toFrame());
        e.* = .{};
    }
    free_frame(ctx, l2_phys);
}

fn releaseL1All(l1_phys: u64, free_frame: FreeFrameFn, ctx: ?*anyopaque) void {
    const l1 = @as(*PageTable, @ptrFromInt(l1_phys));
    for (&l1.entries) |*e| {
        if (!e.isPresent()) continue;
        releaseL2All(e.toFrame(), free_frame, ctx);
        e.* = .{};
    }
    free_frame(ctx, l1_phys);
}

/// 释放 PGD **用户半区**子树（索引 **[0, user_half_l0_end_exclusive)**）；**不**动 `[kernel_linked_l0_begin, 2048)`。
/// 与 `vm.linkKernelHalfMappings` 复制的内核半区互补；参见规格文档。
pub fn releaseUserHalfAddressSpace(pgd_phys: u64, free_frame: FreeFrameFn, ctx: ?*anyopaque) void {
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    var i: usize = 0;
    while (i < user_half_l0_end_exclusive) : (i += 1) {
        var l0e = &pgd.entries[i];
        if (!l0e.isPresent()) continue;
        const l1_phys = l0e.toFrame();
        releaseL1All(l1_phys, free_frame, ctx);
        l0e.* = .{};
    }
}

/// 枚举 PGD 用户半区下 **16KiB 用户叶**（`V` 且 `PLV==PLV_USER`）。名称保留以与 x86 `forEachUser4KiPresentLeaf` 一致。
pub fn forEachUser4KiPresentLeaf(
    pgd_phys: u64,
    ctx: ?*anyopaque,
    cb: *const fn (ctx: ?*anyopaque, virt: u64, phys: u64, pte_raw: u64) bool,
) bool {
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    var li0: usize = 0;
    while (li0 < user_half_l0_end_exclusive) : (li0 += 1) {
        const l0e = &pgd.entries[li0];
        if (!l0e.isPresent()) continue;
        const l1 = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
        var li1: usize = 0;
        while (li1 < 2048) : (li1 += 1) {
            const l1e = &l1.entries[li1];
            if (!l1e.isPresent()) continue;
            const l2 = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
            var li2: usize = 0;
            while (li2 < 2048) : (li2 += 1) {
                const l2e = &l2.entries[li2];
                if (!l2e.isPresent()) continue;
                const raw = l2e.raw;
                if (!isUserLeafRaw(raw)) continue;
                const virt = (@as(u64, @intCast(li0)) << L0_SHIFT) |
                    (@as(u64, @intCast(li1)) << L1_SHIFT) |
                    (@as(u64, @intCast(li2)) << L2_SHIFT);
                if (!cb(ctx, virt, l2e.toFrame(), raw)) return false;
            }
        }
    }
    return true;
}

/// 替换已存在 **16KiB 叶** 的物理帧（CoW）；`flags` 为完整叶标志（含 `D` 可写）。
pub fn remapLeafPhysical(
    pgd_phys: u64,
    virt: u64,
    new_phys: u64,
    flags: u64,
    _: AllocFrameFn,
    _: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const aligned = new_phys & ADDR_MASK;
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return false;
    const l1 = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1e = &l1.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const l2 = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2e = &l2.entries[v.ptIndex()];
    if (!l2e.isPresent()) return false;
    l2e.* = PageTableEntry.fromFrame(aligned, flags | D);
    invtlbAddrVa(virt & ~@as(u64, @intCast(page_mask)));
    noteCurrentPageTablePossiblyMutated(pgd_phys);
    return true;
}

/// `block_base` 须 32MiB 对齐；整表 identity 映射（减少启动时 `mapPage` 次）。
pub fn mapIdentity32MiBlock(
    pgd_phys: u64,
    block_base: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    if ((block_base % identity_bulk_bytes) != 0) return false;
    const v = VirtAddr{ .value = block_base };
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));

    var l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l0e.* = .{ .raw = (frame & ADDR_MASK) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }
    const l1_table = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    var l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l1e.* = .{ .raw = (frame & ADDR_MASK) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }
    const l2_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    var i: usize = 0;
    while (i < 2048) : (i += 1) {
        if (l2_table.entries[i].isPresent()) return false;
        const virt = block_base + i * page_size;
        l2_table.entries[i] = PageTableEntry.fromFrame(virt, flags);
    }
    invtlbAll();
    noteCurrentPageTablePossiblyMutated(pgd_phys);
    return true;
}

pub fn mapPage(
    pgd_phys: u64,
    virt: u64,
    phys: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const aligned_phys = phys & ADDR_MASK;

    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));

    const l0_idx = v.pml4Index();
    var l0e = &pgd.entries[l0_idx];
    if (!l0e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l0e.* = .{ .raw = (frame & ADDR_MASK) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const l1_table = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1_idx = v.pdptIndex();
    var l1e = &l1_table.entries[l1_idx];
    if (!l1e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l1e.* = .{ .raw = (frame & ADDR_MASK) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const l2_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2_idx = v.ptIndex();
    var l2e = &l2_table.entries[l2_idx];
    if (l2e.isPresent()) return false;
    l2e.* = PageTableEntry.fromFrame(aligned_phys, flags);
    invtlbAddrVa(virt & ~@as(u64, @intCast(page_mask)));
    noteCurrentPageTablePossiblyMutated(pgd_phys);
    return true;
}

pub fn unmapPage(pgd_phys: u64, virt: u64, _: AllocFrameFn, _: ?*anyopaque) bool {
    const v = VirtAddr{ .value = virt };
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return false;
    const l1_table = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const l2_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2e = &l2_table.entries[v.ptIndex()];
    if (!l2e.isPresent()) return false;
    l2e.* = .{};
    invtlbAddrVa(virt & ~@as(u64, @intCast(page_mask)));
    noteCurrentPageTablePossiblyMutated(pgd_phys);
    return true;
}

/// 更新已存在 **16KiB 叶** 的保护位（`flags` 为 `Present|User|Write|NoExecute` 等与 `vm.ntProtectToPteFlags` 一致的集合）。
/// 无 x86 式大页拆分：叶始终在 L2。
pub fn protectLeafPage(
    pgd_phys: u64,
    virt: u64,
    flags: u64,
    _: AllocFrameFn,
    _: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return false;
    const l1_table = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const l2_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2e = &l2_table.entries[v.ptIndex()];
    if (!l2e.isPresent()) return false;
    const frame = l2e.toFrame();
    const merged = flags | Present | Accessed;
    l2e.* = PageTableEntry.fromFrame(frame, merged);
    invtlbAddrVa(virt & ~@as(u64, @intCast(page_mask)));
    noteCurrentPageTablePossiblyMutated(pgd_phys);
    return true;
}

pub fn loadCr3(phys: u64) void {
    if (builtin.os.tag != .freestanding) return;
    if (phys == last_loaded_pgdl_phys) return;
    asm volatile ("csrwr %[val], 0x18"
        :
        : [val] "r" (phys),
    );
    invtlbAll();
    last_loaded_pgdl_phys = phys;
}

var release_user_half_free_count: usize = 0;

fn protectLeafTestNoopAlloc(_: ?*anyopaque) ?u64 {
    return null;
}

fn releaseUserHalfCountingFree(ctx: ?*anyopaque, phys: u64) void {
    _ = ctx;
    _ = phys;
    release_user_half_free_count += 1;
}

test "loongarch VirtAddr indices for 0x4000" {
    const va = VirtAddr{ .value = 0x4000 };
    try std.testing.expectEqual(@as(u16, 0), va.pml4Index());
    try std.testing.expectEqual(@as(u16, 0), va.pdptIndex());
    try std.testing.expectEqual(@as(u16, 1), va.ptIndex());
}

test "releaseUserHalfAddressSpace frees 16K leaf and three tables" {
    if (builtin.cpu.arch != .loongarch64) return error.SkipZigTest;

    var backing: [5 * 16384]u8 align(16384) = undefined;
    const pgd_mem = backing[0..16384];
    const l1_mem = backing[16384 .. 2 * 16384];
    const l2_mem = backing[2 * 16384 .. 3 * 16384];
    const data_mem = backing[3 * 16384 .. 4 * 16384];
    const kern_l1_mem = backing[4 * 16384 .. 5 * 16384];

    const pgd_phys = @intFromPtr(pgd_mem.ptr);
    const l1_phys = @intFromPtr(l1_mem.ptr);
    const l2_phys = @intFromPtr(l2_mem.ptr);
    const data_phys = @intFromPtr(data_mem.ptr);
    const kern_l1_phys = @intFromPtr(kern_l1_mem.ptr);

    const pgd = @as(*PageTable, @ptrCast(pgd_mem.ptr));
    pgd.zero();
    const l1 = @as(*PageTable, @ptrCast(l1_mem.ptr));
    l1.zero();
    const l2 = @as(*PageTable, @ptrCast(l2_mem.ptr));
    l2.zero();
    const kern_l1 = @as(*PageTable, @ptrCast(kern_l1_mem.ptr));
    kern_l1.zero();

    // VA 0x4000：L0[0] -> L1[0] -> L2[1] -> user data
    pgd.entries[0] = .{ .raw = (l1_phys & ADDR_MASK) | V };
    l1.entries[0] = .{ .raw = (l2_phys & ADDR_MASK) | V };
    l2.entries[1] = PageTableEntry.fromFrame(data_phys, PLV_USER | D);

    pgd.entries[kernel_linked_l0_begin] = .{ .raw = (kern_l1_phys & ADDR_MASK) | V };

    release_user_half_free_count = 0;
    releaseUserHalfAddressSpace(pgd_phys, releaseUserHalfCountingFree, null);

    try std.testing.expectEqual(@as(usize, 3), release_user_half_free_count);
    try std.testing.expect(pgd.entries[kernel_linked_l0_begin].isPresent());
}

test "protectLeafPage applies NX for PAGE_READONLY equivalent flags" {
    if (builtin.cpu.arch != .loongarch64) return error.SkipZigTest;

    var backing: [4 * 16384]u8 align(16384) = undefined;
    const pgd_mem = backing[0..16384];
    const l1_mem = backing[16384 .. 2 * 16384];
    const l2_mem = backing[2 * 16384 .. 3 * 16384];
    const data_mem = backing[3 * 16384 .. 4 * 16384];

    const pgd_phys = @intFromPtr(pgd_mem.ptr);
    const l1_phys = @intFromPtr(l1_mem.ptr);
    const l2_phys = @intFromPtr(l2_mem.ptr);
    const data_phys = @intFromPtr(data_mem.ptr);

    const pgd = @as(*PageTable, @ptrCast(pgd_mem.ptr));
    pgd.zero();
    const l1 = @as(*PageTable, @ptrCast(l1_mem.ptr));
    l1.zero();
    const l2 = @as(*PageTable, @ptrCast(l2_mem.ptr));
    l2.zero();

    pgd.entries[0] = .{ .raw = (l1_phys & ADDR_MASK) | V };
    l1.entries[0] = .{ .raw = (l2_phys & ADDR_MASK) | V };
    l2.entries[0] = PageTableEntry.fromFrame(data_phys, PLV_USER | D);

    const ro_user = Present | User | Accessed | NoExecute;
    try std.testing.expect(protectLeafPage(pgd_phys, 0, ro_user, protectLeafTestNoopAlloc, null));
    const pte = l2.entries[0];
    try std.testing.expect(pte.isPresent());
    try std.testing.expect((pte.raw & NX) != 0);
    try std.testing.expect((pte.raw & D) == 0);
    try std.testing.expect(isUserLeafRaw(pte.raw));
}
