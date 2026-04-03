//! Physical Frame Allocator
//! PFN 数据库基本版：每 PFN `flink`/`blink` 挂入 **Free / Zeroed** 按 NUMA 区占位三元组（dma/normal/high）链表；
//! 单页分配 O(1) 弹出；位图与 `pfn_meta` 同步维护供连续分配 O(n) 扫描与调试。
//! NT 行为子集：零页链表优先满足 `allocZeroed`（公开文档级「zeroed page list」概念，clean-room）。
//!
//! Ref: Multiboot2 memory map; Intel SDM physical addressing; OS textbook intrusive doubly-linked free lists.
//! Physical span: `build.zig -Dphys_track_gb=8|16|32|64` → `build_options.phys_track_gb` (default 8).

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("../arch.zig");
const boot_mod = arch.impl.boot;
const build_cfg = @import("build_options");
const mb2_gop = @import("../boot/multiboot2_parse.zig");
const klog = @import("../rtl/klog.zig");

pub const FRAME_SIZE: usize = arch.PAGE_SIZE;

/// 链表「空」哨兵（合法 PFN 下标恒 &lt; 2^20..2^27 量级，远小于 u32::MAX）。
pub const pfn_list_nil: u32 = std.math.maxInt(u32);

/// Multiboot2 可用 / 非可用区间收集上限（UEFI 常见 100+ 条 mmap；96 会静默丢弃尾部条目并严重低估 `total_frames`）。
const mmap_non_ram_cap: usize = 256;

const MmapPhysSpan = struct { start: u64, end_excl: u64 };

fn sortPhysSpans(spans: []MmapPhysSpan) void {
    var a: usize = 0;
    while (a < spans.len) : (a += 1) {
        var b = a + 1;
        while (b < spans.len) : (b += 1) {
            if (spans[b].start < spans[a].start) {
                const t = spans[a];
                spans[a] = spans[b];
                spans[b] = t;
            }
        }
    }
}

/// `in` 已按 `start` 升序；合并重叠与相邻区间，返回写入 `out` 的条数。
fn mergePhysSpans(in: []const MmapPhysSpan, out: []MmapPhysSpan) usize {
    if (in.len == 0) return 0;
    var o: usize = 0;
    var i: usize = 0;
    while (i < in.len) {
        const s = in[i].start;
        var e = in[i].end_excl;
        i += 1;
        while (i < in.len and in[i].start <= e) {
            e = @max(e, in[i].end_excl);
            i += 1;
        }
        if (o < out.len) {
            out[o] = .{ .start = s, .end_excl = e };
            o += 1;
        }
    }
    return o;
}

/// `holes` 已按 `start` 升序且已合并；从 `[range_start, range_end_excl)` 减去与 holes 的交，写入 `out`（容量须 ≥ holes.len + 1）。
/// 将每页对 holes 的 O(|holes|) 扫描降为每段 O(|holes|)，避免启动期数百万页 × 数十洞 ≈ 亿级比较导致「卡在 Multiboot2 之后」。
fn subtractNonRamFromRange(range_start: u64, range_end_excl: u64, holes: []const MmapPhysSpan, out: []MmapPhysSpan) usize {
    if (range_end_excl <= range_start) return 0;
    var cur = range_start;
    var o: usize = 0;
    for (holes) |h| {
        if (h.end_excl <= cur) continue;
        if (h.start >= range_end_excl) break;
        if (cur < h.start) {
            const seg_end = @min(h.start, range_end_excl);
            if (o >= out.len) return o;
            out[o] = .{ .start = cur, .end_excl = seg_end };
            o += 1;
            if (seg_end >= range_end_excl) return o;
        }
        cur = @max(cur, h.end_excl);
        if (cur >= range_end_excl) return o;
    }
    if (cur < range_end_excl) {
        if (o >= out.len) return o;
        out[o] = .{ .start = cur, .end_excl = range_end_excl };
        o += 1;
    }
    return o;
}

fn flushDebugSerialIfPossible() void {
    if (builtin.os.tag == .freestanding) arch.flushDebugSerialOutput();
}

/// 清零一帧；`phys` 须为可写 GPA（内核恒等映射）或主机测试池指针。
/// x86_64 内核：`rep stosq`；主机 `zig test` 用 `u64` 循环（避免用户态内联汇编与约束差异导致 SIGSEGV）。
/// 调试：QEMU `-S -s` + `target remote :1234`，`break memsetPhysicalPage`（或 `rb *memsetPhysicalPage`）；#PF 时 `info registers cr2 rip`。
/// ISA 调试口 0xE9：Debug 下进/出 `rep stosq` 各写一字节（Bochs/QEMU `-d guest_errors` 等可见）。
pub fn memsetPhysicalPage(phys: u64) void {
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        if (klog.DEBUG_MODE) {
            asm volatile ("outb %[t], $0xe9"
                :
                : [t] "{al}" (@as(u8, 0xA1)),
                : .{ .memory = true }
            );
        }
        asm volatile (
            \\cld
            \\rep stosq
            :
            : [rdi] "{rdi}" (phys),
              [rcx] "{rcx}" (@as(usize, 512)),
              [rax] "{rax}" (@as(usize, 0)),
            : .{ .rdi = true, .rcx = true, .rax = true, .memory = true }
        );
        if (klog.DEBUG_MODE) {
            asm volatile ("outb %[t], $0xe9"
                :
                : [t] "{al}" (@as(u8, 0xA2)),
                : .{ .memory = true }
            );
        }
        return;
    }
    var i: usize = 0;
    const p: [*]volatile u64 = @ptrFromInt(phys);
    while (i < 512) : (i += 1) p[i] = 0;
}

/// CoW / 填页（约定同 `memsetPhysicalPage`）。
pub fn memcpyPhysicalPage(dst_phys: u64, src_phys: u64) void {
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        asm volatile (
            \\cld
            \\rep movsq
            :
            : [rdi] "{rdi}" (dst_phys),
              [rsi] "{rsi}" (src_phys),
              [rcx] "{rcx}" (@as(usize, 512)),
            : .{ .rdi = true, .rsi = true, .rcx = true, .memory = true }
        );
        return;
    }
    var i: usize = 0;
    const d: [*]volatile u64 = @ptrFromInt(dst_phys);
    const s: [*]const volatile u64 = @ptrFromInt(src_phys);
    while (i < 512) : (i += 1) d[i] = s[i];
}

pub const MAX_PHYS_FRAMES: usize = @as(usize, @intCast(build_cfg.phys_track_gb)) * (1024 * 1024 * 1024) / FRAME_SIZE;
pub const BITMAP_SIZE: usize = (MAX_PHYS_FRAMES + 63) / 64;

pub const ZONE_DMA_PHYS_MAX: u64 = 16 * 1024 * 1024;
pub const ZONE_NORMAL_PHYS_MAX: u64 = 0x1_0000_0000;

pub const MemoryZone = enum(u8) {
    dma,
    normal,
    high,
};

pub const PfnState = enum(u8) {
    unused = 0,
    free = 1,
    active = 2,
    zeroed = 3,
    reserved = 4,
    buddy_arena = 5,
    standby = 6,
};

pub var kernel_frame_alloc: ?*FrameAllocator = null;
pub var g_kernel_frame_storage: FrameAllocator = undefined;

pub fn setKernelFrameAllocator(a: ?*FrameAllocator) void {
    kernel_frame_alloc = a;
}

pub fn getKernelFrameAllocator() ?*FrameAllocator {
    return kernel_frame_alloc;
}

pub fn kernelFrameAllocatorPtr() *FrameAllocator {
    return &g_kernel_frame_storage;
}

pub fn initGlobalKernelFrames(boot_info: ?boot_mod.BootInfo, kernel_end: usize) void {
    g_kernel_frame_storage.init(boot_info, kernel_end);
    setKernelFrameAllocator(&g_kernel_frame_storage);
}

pub fn zoneForPhysAddr(phys: u64) MemoryZone {
    if (phys < ZONE_DMA_PHYS_MAX) return .dma;
    if (phys < ZONE_NORMAL_PHYS_MAX) return .normal;
    return .high;
}

fn frameIndexInZoneAlloc(fa: *const FrameAllocator, frame: usize, zone: MemoryZone) bool {
    if (fa.host_test_mode) return frame < fa.total_frames;
    const phys = @as(u64, @intCast(frame)) * @as(u64, @intCast(FRAME_SIZE));
    return zoneForPhysAddr(phys) == zone;
}

fn zoneToIdx(z: MemoryZone) usize {
    return switch (z) {
        .dma => 0,
        .normal => 1,
        .high => 2,
    };
}

pub const FrameAllocator = struct {
    bitmap: [BITMAP_SIZE]u64,
    pfn_meta: [MAX_PHYS_FRAMES]u8,
    pfn_locks: [MAX_PHYS_FRAMES]u8,
    /// CoW / 共享物理页引用计数；无共享时为 0；`notePageShared` 用于 fork/视图共享。
    pfn_share_count: [MAX_PHYS_FRAMES]u16,
    pfn_flink: [MAX_PHYS_FRAMES]u32,
    pfn_blink: [MAX_PHYS_FRAMES]u32,
    /// 每 zone 一条空闲链（dma/normal/high）。
    free_head: [3]u32,
    /// 已清零、可直接满足 `allocZeroed` 的页（每 zone 一条）。
    zeroed_head: [3]u32,
    total_frames: usize,
    used_frames: usize,
    mb_handoff_start: usize = 0,
    mb_handoff_end_exclusive: usize = 0,
    /// 主机 `zig test`：`alloc` 返回的「PFN」为 `host_test_base + slot*4096`（可写宿主内存）；裸机恒为 false。
    host_test_mode: bool = false,
    host_test_base: u64 = 0,
    /// GOP/UEFI 帧缓冲物理区间（页对齐），须从可用 mmap 中剔除，避免 `allocZeroed`→`memsetPhysicalPage` 写显存挂死。
    fb_reserve_start: u64 = 0,
    fb_reserve_end_exclusive: u64 = 0,
    /// `init` 传入的映像末尾（首字节不属于内核，VA=PA）；Debug 下 `memsetPhysicalPage` 前自检。单元测试置 0 则跳过。
    boot_kernel_end_exclusive: usize = 0,

    fn pfnSlotFromPhys(self: *const FrameAllocator, phys: u64) ?usize {
        if (self.host_test_mode) {
            if (phys < self.host_test_base) return null;
            const off = phys - self.host_test_base;
            if ((off % FRAME_SIZE) != 0) return null;
            const slot: usize = @intCast(off / FRAME_SIZE);
            if (slot >= self.total_frames or slot >= MAX_PHYS_FRAMES) return null;
            return slot;
        }
        const slot: usize = @intCast(phys / FRAME_SIZE);
        if (slot >= MAX_PHYS_FRAMES) return null;
        return slot;
    }

    fn physFromSlot(self: *const FrameAllocator, slot: usize) u64 {
        if (self.host_test_mode) {
            return self.host_test_base +% @as(u64, @intCast(slot * FRAME_SIZE));
        }
        return @as(u64, @intCast(slot * FRAME_SIZE));
    }

    /// `memsetPhysicalPage` 前自检：对齐且在 PFN 槽可解析范围内，避免对非法 GPA 写导致挂死。
    pub fn isPhysPlausibleForZeroFill(self: *const FrameAllocator, phys: u64) bool {
        if (phys == 0) return false;
        if ((phys & (FRAME_SIZE - 1)) != 0) return false;
        return self.pfnSlotFromPhys(phys) != null;
    }

    /// Debug + 裸机：在清零前断言 GPA 不在内核映像与帧分配器自占区（防止回归 `stack_top` 低估 `_kernel_end`）。
    fn debugAssertPhysSafeBeforeKernelZeroFill(self: *FrameAllocator, phys: u64) void {
        if (!klog.DEBUG_MODE) return;
        if (builtin.os.tag != .freestanding) return;
        if (self.host_test_mode) return;
        if (self.boot_kernel_end_exclusive == 0) return;

        const ke: u64 = @intCast(self.boot_kernel_end_exclusive);
        if (phys < ke) {
            klog.err("BUG: memsetPhysicalPage GPA 0x%x below boot_kernel_end_exclusive 0x%x", .{ phys, ke });
            arch.halt();
        }
        const cache = bootSeedReservedCacheFrom(self, self.boot_kernel_end_exclusive);
        if (phys >= cache.bitmap_addr_first and phys < cache.bitmap_addr_past) {
            klog.err("BUG: memsetPhysicalPage GPA 0x%x overlaps frame bitmap", .{phys});
            arch.halt();
        }
        if (phys >= cache.pfn_tbl_addr_first and phys < cache.pfn_tbl_addr_past) {
            klog.err("BUG: memsetPhysicalPage GPA 0x%x overlaps PFN metadata tables", .{phys});
            arch.halt();
        }
    }

    pub fn init(self: *FrameAllocator, boot_info: ?boot_mod.BootInfo, kernel_end: usize) void {
        self.boot_kernel_end_exclusive = kernel_end;
        for (&self.bitmap) |*b| b.* = 0;
        @memset(&self.pfn_meta, @intFromEnum(PfnState.unused));
        @memset(&self.pfn_locks, 0);
        @memset(&self.pfn_share_count, 0);
        @memset(&self.pfn_flink, 0);
        @memset(&self.pfn_blink, 0);
        for (&self.free_head) |*h| h.* = pfn_list_nil;
        for (&self.zeroed_head) |*h| h.* = pfn_list_nil;
        self.total_frames = 0;
        self.used_frames = 0;
        self.mb_handoff_start = 0;
        self.mb_handoff_end_exclusive = 0;
        self.fb_reserve_start = 0;
        self.fb_reserve_end_exclusive = 0;

        const info = boot_info orelse return;

        if (info.multiboot_handoff_end_exclusive > info.multiboot_handoff_start) {
            self.mb_handoff_start = info.multiboot_handoff_start;
            self.mb_handoff_end_exclusive = info.multiboot_handoff_end_exclusive;
        }

        if (info.fb_info) |fb| {
            const coerced: mb2_gop.FramebufferInfo = .{
                .addr = fb.addr,
                .pitch = fb.pitch,
                .width = fb.width,
                .height = fb.height,
                .bpp = fb.bpp,
                .fb_type = fb.fb_type,
            };
            const r = mb2_gop.gopPhysicalReserveRange(coerced, @as(u64, FRAME_SIZE));
            self.fb_reserve_start = r.start;
            self.fb_reserve_end_exclusive = r.end_exclusive;
        }

        // Ref: Multiboot2 memory map — reserved / ACPI / NVS / bad must not be allocated even if an
        // "available" entry incorrectly overlaps (clean-room hole punch vs E820 semantics).
        var nram_raw: [mmap_non_ram_cap]MmapPhysSpan = undefined;
        var nram_n: usize = 0;
        var nram_dropped: usize = 0;
        var mi: usize = 0;
        while (mi < info.mmap_entry_count) : (mi += 1) {
            const e = info.getMmapEntry(mi) orelse break;
            if (e.length == 0) continue;
            if (e.type == @intFromEnum(boot_mod.MmapEntryType.available)) continue;
            if (e.base_addr > std.math.maxInt(u64) - e.length) continue;
            if (nram_n < nram_raw.len) {
                nram_raw[nram_n] = .{ .start = e.base_addr, .end_excl = e.base_addr + e.length };
                nram_n += 1;
            } else {
                nram_dropped +%= 1;
            }
        }
        sortPhysSpans(nram_raw[0..nram_n]);
        var nram_merged_buf: [mmap_non_ram_cap]MmapPhysSpan = undefined;
        const nram_mn = mergePhysSpans(nram_raw[0..nram_n], &nram_merged_buf);
        const nram_merged = nram_merged_buf[0..nram_mn];
        if (builtin.os.tag == .freestanding) {
            klog.info("Frame: mmap non-RAM spans merged=%u (subtract from available; plug MMIO falsely marked available)", .{nram_mn});
        }

        // 合并重叠/相邻的 available 区再入队，避免同一 PFN 被多次 `listPrepend` 破坏空闲链。
        var avail_raw: [mmap_non_ram_cap]MmapPhysSpan = undefined;
        var avail_n: usize = 0;
        var avail_dropped: usize = 0;
        mi = 0;
        while (mi < info.mmap_entry_count) : (mi += 1) {
            const entry = info.getMmapEntry(mi) orelse break;
            if (entry.type != @intFromEnum(boot_mod.MmapEntryType.available)) continue;
            if (entry.length == 0) continue;
            const base = entry.base_addr;
            const len = entry.length;
            if (base > std.math.maxInt(u64) - len) continue;
            if (avail_n < avail_raw.len) {
                avail_raw[avail_n] = .{ .start = base, .end_excl = base + len };
                avail_n += 1;
            } else {
                avail_dropped +%= 1;
            }
        }
        sortPhysSpans(avail_raw[0..avail_n]);
        var avail_merged_buf: [mmap_non_ram_cap]MmapPhysSpan = undefined;
        const avail_mn = mergePhysSpans(avail_raw[0..avail_n], &avail_merged_buf);
        const avail_merged = avail_merged_buf[0..avail_mn];

        var sub_frag: [mmap_non_ram_cap + 1]MmapPhysSpan = undefined;
        if (nram_dropped != 0) {
            klog.warn("Frame: Multiboot2 non-RAM mmap entries truncated (cap=%u, dropped=%u)", .{ mmap_non_ram_cap, nram_dropped });
        }
        if (avail_dropped != 0) {
            klog.warn("Frame: Multiboot2 available mmap entries truncated (cap=%u, dropped=%u)", .{ mmap_non_ram_cap, avail_dropped });
        }
        const seed_cache = bootSeedReservedCacheFrom(self, kernel_end);
        var seeded_progress: usize = 0;
        var next_progress_log: usize = 1 << 17;
        for (avail_merged) |span| {
            const nsub = subtractNonRamFromRange(span.start, span.end_excl, nram_merged, &sub_frag);
            for (sub_frag[0..nsub]) |sub| {
                if (sub.end_excl <= sub.start) continue;
                var cur: usize = @intCast(sub.start / @as(u64, @intCast(FRAME_SIZE)));
                const sub_end: usize = @intCast(sub.end_excl / @as(u64, @intCast(FRAME_SIZE)));
                const limit = @min(sub_end, MAX_PHYS_FRAMES);
                while (cur < limit) {
                    if (isReservedBootSeed(cur, &seed_cache)) {
                        cur += 1;
                        continue;
                    }
                    const rs = cur;
                    while (cur < limit) {
                        if (isReservedBootSeed(cur, &seed_cache)) break;
                        cur += 1;
                    }
                    self.seedFreeRunByZoneSplit(rs, cur, &seeded_progress, &next_progress_log);
                }
            }
        }
    }

    /// 同一 `MemoryZone` 内连续 PFN：按字 OR 位图、`@memset` meta、一次性 prepend 整条链（等价于逐页 `enqueueFreeFrame`，少 2M 次 `listPrepend` 调用栈与分支）。
    fn prependFreeRunInZone(
        self: *FrameAllocator,
        zidx: usize,
        lo: usize,
        hi_excl: usize,
        seeded: *usize,
        next_log: *usize,
    ) void {
        if (lo >= hi_excl) return;
        std.debug.assert(zidx < 3);
        const n = hi_excl - lo;
        var f = lo;
        while (f < hi_excl) {
            const w = f / 64;
            const bit_start = f % 64;
            const bits_in_word: usize = @min(64 - bit_start, hi_excl - f);
            const mask: u64 = if (bit_start == 0 and bits_in_word == 64)
                std.math.maxInt(u64)
            else
                ((@as(u64, 1) << @intCast(bits_in_word)) -% 1) << @intCast(bit_start);
            if (w < BITMAP_SIZE) self.bitmap[w] |= mask;
            f += bits_in_word;
        }
        @memset(self.pfn_meta[lo..hi_excl], @intFromEnum(PfnState.free));
        const old = self.free_head[zidx];
        const first = lo;
        const last = hi_excl - 1;
        if (first == last) {
            const fi: u32 = @intCast(first);
            self.pfn_flink[first] = old;
            self.pfn_blink[first] = pfn_list_nil;
            if (old != pfn_list_nil) self.pfn_blink[@intCast(old)] = fi;
            self.free_head[zidx] = fi;
        } else {
            var i = first;
            while (i < last) : (i += 1) {
                self.pfn_flink[i] = @intCast(i + 1);
                self.pfn_blink[i + 1] = @intCast(i);
            }
            self.pfn_flink[last] = old;
            self.pfn_blink[first] = pfn_list_nil;
            self.pfn_blink[last] = @intCast(last - 1);
            if (old != pfn_list_nil) {
                self.pfn_blink[@intCast(old)] = @intCast(last);
            }
            self.free_head[zidx] = @intCast(first);
        }
        self.total_frames += n;
        seeded.* += n;
        if (klog.DEBUG_MODE and builtin.os.tag == .freestanding) {
            const milestone: usize = 1 << 17;
            while (seeded.* >= next_log.*) {
                klog.debug("Frame: seeding PFN progress %u", .{seeded.*});
                flushDebugSerialIfPossible();
                next_log.* += milestone;
            }
        }
    }

    /// 将一段已判定「全非保留」的 PFN 区间按 dma/normal/high 边界切开并批量入链。
    fn seedFreeRunByZoneSplit(
        self: *FrameAllocator,
        lo: usize,
        hi_excl: usize,
        seeded: *usize,
        next_log: *usize,
    ) void {
        const pfn_dma_end: usize = @intCast(ZONE_DMA_PHYS_MAX / @as(u64, @intCast(FRAME_SIZE)));
        const pfn_norm_end: usize = @intCast(ZONE_NORMAL_PHYS_MAX / @as(u64, @intCast(FRAME_SIZE)));
        var a = lo;
        const cap = @min(hi_excl, MAX_PHYS_FRAMES);
        while (a < cap) {
            const phys = @as(u64, @intCast(a)) * @as(u64, @intCast(FRAME_SIZE));
            const zidx = zoneToIdx(zoneForPhysAddr(phys));
            const seg_end: usize = switch (zoneForPhysAddr(phys)) {
                .dma => @min(cap, pfn_dma_end),
                .normal => @min(cap, pfn_norm_end),
                .high => cap,
            };
            if (seg_end <= a) break;
            self.prependFreeRunInZone(zidx, a, seg_end, seeded, next_log);
            a = seg_end;
        }
    }

    fn isReserved(self: *FrameAllocator, frame: u64, kernel_end: usize) bool {
        const fs_u64: u64 = @intCast(FRAME_SIZE);
        if (frame > std.math.maxInt(u64) / fs_u64) return true;
        const addr = frame * fs_u64;
        if (addr < 0x100000) return true;
        if (addr < kernel_end) return true;
        if (self.mb_handoff_end_exclusive > self.mb_handoff_start) {
            const hs = self.mb_handoff_start;
            const he = self.mb_handoff_end_exclusive;
            const past_ok = addr <= std.math.maxInt(u64) - fs_u64;
            if (addr < he and past_ok and addr + fs_u64 > hs) return true;
            if (addr < he and !past_ok) return true;
        }
        const bitmap_begin = @intFromPtr(&self.bitmap);
        const bitmap_bytes = BITMAP_SIZE * @sizeOf(u64);
        const bitmap_first = bitmap_begin & ~@as(usize, FRAME_SIZE - 1);
        if (bitmap_begin > std.math.maxInt(usize) - bitmap_bytes) return true;
        const bitmap_past = std.mem.alignForward(usize, bitmap_begin + bitmap_bytes, FRAME_SIZE);
        if (addr >= bitmap_first and addr < bitmap_past) return true;
        // PFN 链表数组驻留在内核 BSS，与位图同一保留策略。
        const fl_begin = @intFromPtr(&self.pfn_flink);
        const fl_bytes = MAX_PHYS_FRAMES * @sizeOf(u32) * 2 + MAX_PHYS_FRAMES * @sizeOf(u16);
        const fl_first = fl_begin & ~@as(usize, FRAME_SIZE - 1);
        if (fl_begin > std.math.maxInt(usize) - fl_bytes) return true;
        const fl_past = std.mem.alignForward(usize, fl_begin + fl_bytes, FRAME_SIZE);
        if (addr >= fl_first and addr < fl_past) return true;
        // GOP：`fb_reserve_*` 来自 `multiboot2_parse.gopPhysicalReserveRange`；其余固件误标为 available 的设备区靠 `init` 内 non-RAM mmap 孔洞剔除（PHYS_ALLOC_AUDIT.md）。
        if (self.fb_reserve_end_exclusive > self.fb_reserve_start) {
            const page_after = addr +% fs_u64;
            if (page_after > addr and
                addr < self.fb_reserve_end_exclusive and
                page_after > self.fb_reserve_start)
            {
                return true;
            }
        }
        return false;
    }

    fn setPfn(self: *FrameAllocator, frame: usize, st: PfnState) void {
        if (frame < MAX_PHYS_FRAMES) self.pfn_meta[frame] = @intFromEnum(st);
    }

    fn getPfn(self: *const FrameAllocator, frame: usize) PfnState {
        if (frame >= MAX_PHYS_FRAMES) return .unused;
        return @enumFromInt(self.pfn_meta[frame]);
    }

    fn bitmapMarkFree(self: *FrameAllocator, frame: usize) void {
        const word = frame / 64;
        const bit = frame % 64;
        if (word < BITMAP_SIZE) {
            self.bitmap[word] |= @as(u64, 1) << @intCast(bit);
        }
    }

    fn bitmapMarkUsed(self: *FrameAllocator, frame: usize) void {
        const word = frame / 64;
        const bit = frame % 64;
        if (word < BITMAP_SIZE) {
            self.bitmap[word] &= ~(@as(u64, 1) << @intCast(bit));
        }
    }

    fn isFreeBitmap(self: *const FrameAllocator, frame: usize) bool {
        const word = frame / 64;
        const bit = frame % 64;
        if (word >= BITMAP_SIZE) return false;
        return (self.bitmap[word] & (@as(u64, 1) << @intCast(bit))) != 0;
    }

    fn listPrepend(self: *FrameAllocator, heads: *[3]u32, zone_idx: usize, frame: usize) void {
        const fi: u32 = @intCast(frame);
        const old = heads[zone_idx];
        self.pfn_flink[frame] = old;
        self.pfn_blink[frame] = pfn_list_nil;
        if (old != pfn_list_nil) {
            self.pfn_blink[@intCast(old)] = fi;
        }
        heads[zone_idx] = fi;
    }

    fn listPop(self: *FrameAllocator, heads: *[3]u32, zone_idx: usize) ?usize {
        const h = heads[zone_idx];
        if (h == pfn_list_nil) return null;
        const frame: usize = @intCast(h);
        const next = self.pfn_flink[frame];
        heads[zone_idx] = next;
        if (next != pfn_list_nil) {
            self.pfn_blink[@intCast(next)] = pfn_list_nil;
        }
        self.pfn_flink[frame] = pfn_list_nil;
        self.pfn_blink[frame] = pfn_list_nil;
        return frame;
    }

    fn listUnlink(self: *FrameAllocator, heads: *[3]u32, zone_idx: usize, frame: usize) void {
        const fi: u32 = @intCast(frame);
        const next = self.pfn_flink[frame];
        const prev = self.pfn_blink[frame];
        if (prev == pfn_list_nil) {
            // 链表与 meta 不一致时 assert 会触发 Zig panic，串口上与 klog 交错难以辨认；改为停机提示。
            if (heads[zone_idx] != fi) {
                arch.consoleWrite("FRAME: PFN free/zeroed list head mismatch (corrupt list); halting.\n");
                arch.halt();
            }
            heads[zone_idx] = next;
        } else {
            self.pfn_flink[@intCast(prev)] = next;
        }
        if (next != pfn_list_nil) {
            self.pfn_blink[@intCast(next)] = prev;
        }
        self.pfn_flink[frame] = pfn_list_nil;
        self.pfn_blink[frame] = pfn_list_nil;
    }

    /// 从 Free 或 Zeroed 链摘除（`markPhysRangeUsed` / 一致性修复用）。
    fn removeFromFreeOrZeroedLists(self: *FrameAllocator, frame: usize) void {
        const st = self.getPfn(frame);
        if (st != .free and st != .zeroed) return;
        const zidx = zoneToIdx(zoneForPhysAddr(@as(u64, @intCast(frame)) * @as(u64, @intCast(FRAME_SIZE))));
        if (st == .free) {
            self.listUnlink(&self.free_head, zidx, frame);
        } else {
            self.listUnlink(&self.zeroed_head, zidx, frame);
        }
    }

    fn enqueueFreeFrame(self: *FrameAllocator, frame: usize) void {
        const st = self.getPfn(frame);
        if (st == .free or st == .zeroed) return;
        const was_unused = (st == .unused);
        self.bitmapMarkFree(frame);
        self.setPfn(frame, .free);
        const zidx = zoneToIdx(zoneForPhysAddr(@as(u64, @intCast(frame)) * @as(u64, @intCast(FRAME_SIZE))));
        self.listPrepend(&self.free_head, zidx, frame);
        if (was_unused) self.total_frames += 1;
    }

    fn enqueueZeroedFrame(self: *FrameAllocator, frame: usize) void {
        if (self.getPfn(frame) == .zeroed) return;
        self.bitmapMarkFree(frame);
        self.setPfn(frame, .zeroed);
        const zidx = zoneToIdx(zoneForPhysAddr(@as(u64, @intCast(frame)) * @as(u64, @intCast(FRAME_SIZE))));
        self.listPrepend(&self.zeroed_head, zidx, frame);
    }

    fn activateFrame(self: *FrameAllocator, frame: usize) void {
        self.bitmapMarkUsed(frame);
        self.setPfn(frame, .active);
        self.used_frames += 1;
    }

    /// 自指定 zone 弹出一页：先 Zeroed 再 Free（Free 弹出后内容未定义，由调用方决定是否清零）。
    fn popFrameInZoneFixed(self: *FrameAllocator, zone: MemoryZone) ?usize {
        const zi = zoneToIdx(zone);
        if (self.listPop(&self.zeroed_head, zi)) |f| {
            if (self.pfn_locks[f] != 0) {
                self.listPrepend(&self.zeroed_head, zi, f);
                return null;
            }
            return f;
        }
        if (self.listPop(&self.free_head, zi)) |f| {
            if (self.pfn_locks[f] != 0) {
                self.listPrepend(&self.free_head, zi, f);
                return null;
            }
            return f;
        }
        return null;
    }

    /// 伙伴 arena 等已占用但非「活跃匿名页」的帧。
    pub fn markBuddyArenaFrames(self: *FrameAllocator, phys_start: u64, num_pages: usize) void {
        var i: usize = 0;
        while (i < num_pages) : (i += 1) {
            const step = @as(u64, @intCast(i)) * @as(u64, @intCast(FRAME_SIZE));
            if (phys_start > std.math.maxInt(u64) - step) break;
            const phys = phys_start + step;
            const fr = self.pfnSlotFromPhys(phys) orelse continue;
            self.setPfn(fr, .buddy_arena);
        }
    }

    pub fn pfnState(self: *const FrameAllocator, phys: u64) PfnState {
        const fr = self.pfnSlotFromPhys(phys) orelse return .unused;
        return self.getPfn(fr);
    }

    pub fn lockPfnPhys(self: *FrameAllocator, phys: u64) void {
        const fr = self.pfnSlotFromPhys(phys) orelse return;
        if (self.pfn_locks[fr] < 255) self.pfn_locks[fr] += 1;
    }

    pub fn unlockPfnPhys(self: *FrameAllocator, phys: u64) void {
        const fr = self.pfnSlotFromPhys(phys) orelse return;
        if (self.pfn_locks[fr] > 0) self.pfn_locks[fr] -= 1;
    }

    pub fn pfnLockCount(self: *const FrameAllocator, phys: u64) u8 {
        const fr = self.pfnSlotFromPhys(phys) orelse return 0;
        return self.pfn_locks[fr];
    }

    /// 将物理页标为共享（CoW 读共享路径）；新映射同一 PFN 时调用。
    pub fn notePageShared(self: *FrameAllocator, phys: u64) void {
        const fr = self.pfnSlotFromPhys(phys) orelse return;
        if (self.pfn_share_count[fr] < std.math.maxInt(u16)) self.pfn_share_count[fr] += 1;
    }

    pub fn shareCount(self: *const FrameAllocator, phys: u64) u16 {
        const fr = self.pfnSlotFromPhys(phys) orelse return 0;
        return self.pfn_share_count[fr];
    }

    /// 减少共享计数；降至 0 时不自动 `free`（由 `unmap` 路径决定）。
    pub fn releaseShareCount(self: *FrameAllocator, phys: u64) void {
        const fr = self.pfnSlotFromPhys(phys) orelse return;
        if (self.pfn_share_count[fr] > 0) self.pfn_share_count[fr] -= 1;
    }

    /// 默认：优先 normal，其次 high，最后 dma。
    pub fn alloc(self: *FrameAllocator) ?u64 {
        if (self.allocInZone(.normal)) |p| return p;
        if (self.allocInZone(.high)) |p| return p;
        return self.allocInZone(.dma);
    }

    pub fn allocDma(self: *FrameAllocator) ?u64 {
        return self.allocInZone(.dma);
    }

    pub fn allocInZone(self: *FrameAllocator, zone: MemoryZone) ?u64 {
        const frame = self.popFrameInZoneFixed(zone) orelse return null;
        self.activateFrame(frame);
        return self.physFromSlot(frame);
    }

    pub fn isPhysicalPageFree(self: *const FrameAllocator, phys: u64) bool {
        const fr = self.pfnSlotFromPhys(phys) orelse return false;
        return self.isFreeBitmap(fr);
    }

    pub fn free(self: *FrameAllocator, phys: u64) void {
        const frame = self.pfnSlotFromPhys(phys) orelse return;
        if (self.pfn_locks[frame] != 0) return;
        if (self.pfn_share_count[frame] != 0) return;
        const st = self.getPfn(frame);
        if (st == .free or st == .zeroed) return;
        if (self.used_frames > 0) self.used_frames -= 1;
        self.enqueueFreeFrame(frame);
    }

    pub fn allocZeroed(self: *FrameAllocator) ?u64 {
        const zorder = [_]MemoryZone{ .normal, .high, .dma };
        for (zorder) |z| {
            const idx = zoneToIdx(z);
            if (self.listPop(&self.zeroed_head, idx)) |f| {
                // 不在此 assert：Debug 下链不一致会 panic，表现为难以诊断的启动失败。
                self.activateFrame(f);
                const p = self.physFromSlot(f);
                if (klog.DEBUG_MODE and builtin.os.tag == .freestanding) {
                    klog.debug("PFN: allocZeroed reuse zeroed GPA 0x%x (no memset)", .{p});
                    flushDebugSerialIfPossible();
                }
                return p;
            }
        }
        const phys = self.alloc() orelse return null;
        if (!self.isPhysPlausibleForZeroFill(phys)) return null;
        if (klog.DEBUG_MODE and builtin.os.tag == .freestanding) {
            klog.debug("PFN: allocZeroed zero-fill GPA 0x%x (before memsetPhysicalPage)", .{phys});
            flushDebugSerialIfPossible();
        }
        self.debugAssertPhysSafeBeforeKernelZeroFill(phys);
        memsetPhysicalPage(phys);
        if (klog.DEBUG_MODE and builtin.os.tag == .freestanding) flushDebugSerialIfPossible();
        return phys;
    }

    /// Phase3 等路径：优先在 `phys < max_phys_exclusive` 的 PFN 上清零，避免 UEFI 恒等映射未覆盖高 GPA 时 `memsetPhysicalPage` #PF。
    /// 扫描 O(n) 仅用于启动期极少数次分配；失败时调用方应回退 `allocZeroed`。
    pub fn allocZeroedBelowMaxPhys(self: *FrameAllocator, max_phys_exclusive: u64) ?u64 {
        if (max_phys_exclusive == 0) return null;
        const zorder = [_]MemoryZone{ .normal, .high, .dma };
        for (zorder) |z| {
            const idx = zoneToIdx(z);
            if (self.listPop(&self.zeroed_head, idx)) |f| {
                const phys_z = self.physFromSlot(f);
                if (phys_z >= max_phys_exclusive) {
                    self.listPrepend(&self.zeroed_head, idx, f);
                    continue;
                }
                self.activateFrame(f);
                if (klog.DEBUG_MODE and builtin.os.tag == .freestanding) {
                    klog.debug("PFN: allocZeroedBelowMaxPhys reuse zeroed GPA 0x%x (ceiling 0x%x, no memset)", .{
                        phys_z,
                        max_phys_exclusive,
                    });
                    flushDebugSerialIfPossible();
                }
                return phys_z;
            }
        }
        var slot: usize = 0;
        while (slot < MAX_PHYS_FRAMES) : (slot += 1) {
            const phys = self.physFromSlot(slot);
            if (phys >= max_phys_exclusive) break;
            if (phys == 0) continue;
            if (!self.isFreeBitmap(slot)) continue;
            if (self.pfn_locks[slot] != 0) continue;
            const st = self.getPfn(slot);
            if (st != .free and st != .zeroed) continue;
            // 先判定可写 GPA，再摘链；避免摘链/activate 后因 implausible 而 return null 泄漏 PFN。
            if (st == .free and !self.isPhysPlausibleForZeroFill(phys)) continue;
            self.removeFromFreeOrZeroedLists(slot);
            self.activateFrame(slot);
            if (st == .zeroed) {
                if (klog.DEBUG_MODE and builtin.os.tag == .freestanding) {
                    klog.debug("PFN: allocZeroedBelowMaxPhys scan reuse zeroed GPA 0x%x (ceiling 0x%x, no memset)", .{
                        phys,
                        max_phys_exclusive,
                    });
                    flushDebugSerialIfPossible();
                }
                return phys;
            }
            if (klog.DEBUG_MODE and builtin.os.tag == .freestanding) {
                klog.debug("PFN: allocZeroedBelow 0x%x zero-fill GPA 0x%x (before memsetPhysicalPage)", .{
                    max_phys_exclusive,
                    phys,
                });
                flushDebugSerialIfPossible();
            }
            self.debugAssertPhysSafeBeforeKernelZeroFill(phys);
            memsetPhysicalPage(phys);
            if (klog.DEBUG_MODE and builtin.os.tag == .freestanding) flushDebugSerialIfPossible();
            return phys;
        }
        return null;
    }

    /// 连续分配：O(运行空闲区长度) 扫描位图；与单页 O(1) 弹出并存（公开文档级策略说明）。
    pub fn allocContiguous(self: *FrameAllocator, num_frames: usize) ?u64 {
        return self.allocContiguousInZone(num_frames, .normal) orelse
            self.allocContiguousInZone(num_frames, .high) orelse
            self.allocContiguousInZone(num_frames, .dma);
    }

    pub fn allocContiguousInZone(self: *FrameAllocator, num_frames: usize, zone: MemoryZone) ?u64 {
        if (num_frames == 0) return null;
        if (num_frames > MAX_PHYS_FRAMES) return null;
        const limit: usize = MAX_PHYS_FRAMES - num_frames;
        var start: usize = 0;
        while (start <= limit) : (start += 1) {
            if (!frameIndexInZoneAlloc(self, start, zone)) continue;
            if (!frameIndexInZoneAlloc(self, start + num_frames - 1, zone)) continue;
            var all_free = true;
            var i: usize = 0;
            while (i < num_frames) : (i += 1) {
                if (!self.isFreeBitmap(start + i) or self.pfn_locks[start + i] != 0) {
                    all_free = false;
                    break;
                }
            }
            if (!all_free) continue;
            i = 0;
            while (i < num_frames) : (i += 1) {
                self.removeFromFreeOrZeroedLists(start + i);
                self.bitmapMarkUsed(start + i);
                self.setPfn(start + i, .active);
            }
            self.used_frames += num_frames;
            return self.physFromSlot(start);
        }
        return null;
    }

    pub fn freeContiguousRange(self: *FrameAllocator, phys_start: u64, num_pages: usize) void {
        var i: usize = 0;
        while (i < num_pages) : (i += 1) {
            const step = @as(u64, @intCast(i)) * @as(u64, @intCast(FRAME_SIZE));
            if (phys_start > std.math.maxInt(u64) - step) break;
            self.free(phys_start + step);
        }
    }

    pub fn markPhysRangeUsed(self: *FrameAllocator, phys_start: usize, byte_len: usize) void {
        if (byte_len == 0) return;
        if (phys_start > std.math.maxInt(usize) - byte_len) return;
        const ps = FRAME_SIZE;
        var addr = phys_start & ~(ps - 1);
        const end = phys_start + byte_len;
        while (addr < end) {
            const frame_idx: usize = addr / ps;
            if (frame_idx >= MAX_PHYS_FRAMES) break;
            if (self.isFreeBitmap(frame_idx)) {
                self.removeFromFreeOrZeroedLists(frame_idx);
                self.bitmapMarkUsed(frame_idx);
                self.setPfn(frame_idx, .active);
                self.used_frames += 1;
            }
            if (addr > std.math.maxInt(usize) - ps) break;
            addr += ps;
        }
    }

    /// 将 `storage` 绑定为伪 PFN 区（须先 `testSeedLinearFreeFrames` 且 `storage.len / FRAME_SIZE >= total_frames`）。
    pub fn testAttachHostBackedPool(self: *FrameAllocator, storage: []align(FRAME_SIZE) u8) void {
        self.host_test_mode = true;
        self.host_test_base = @intFromPtr(storage.ptr);
    }

    pub fn testSeedLinearFreeFrames(self: *FrameAllocator, num_frames: usize) void {
        self.host_test_mode = false;
        self.host_test_base = 0;
        self.boot_kernel_end_exclusive = 0;
        for (&self.bitmap) |*w| w.* = 0;
        @memset(&self.pfn_meta, @intFromEnum(PfnState.unused));
        @memset(&self.pfn_locks, 0);
        @memset(&self.pfn_share_count, 0);
        @memset(&self.pfn_flink, 0);
        @memset(&self.pfn_blink, 0);
        for (&self.free_head) |*h| h.* = pfn_list_nil;
        for (&self.zeroed_head) |*h| h.* = pfn_list_nil;
        self.total_frames = 0;
        self.used_frames = 0;
        self.mb_handoff_start = 0;
        self.mb_handoff_end_exclusive = 0;
        self.fb_reserve_start = 0;
        self.fb_reserve_end_exclusive = 0;
        var f: usize = 0;
        while (f < num_frames and f < MAX_PHYS_FRAMES) : (f += 1) {
            self.enqueueFreeFrame(f);
        }
    }

    /// 测试：将若干帧放入 Zeroed 链表（不经过清零，仅测 `allocZeroed` 优先路径）。
    pub fn testEnqueueZeroedFrame(self: *FrameAllocator, frame: usize) void {
        if (frame >= MAX_PHYS_FRAMES) return;
        self.removeFromFreeOrZeroedLists(frame);
        self.enqueueZeroedFrame(frame);
    }
};

/// Multiboot 种子热路径缓存（须置于 `FrameAllocator` 定义之后以便引用其布局）。
const BootSeedReservedCache = struct {
    kernel_low_pfn_excl: u64,
    mb_active: bool,
    mb_hs: u64,
    mb_he: u64,
    bitmap_addr_first: u64,
    bitmap_addr_past: u64,
    pfn_tbl_addr_first: u64,
    pfn_tbl_addr_past: u64,
    fb_active: bool,
    fb_start: u64,
    fb_end_excl: u64,
};

fn bootSeedReservedCacheFrom(fa: *FrameAllocator, kernel_end: usize) BootSeedReservedCache {
    const fs_u64: u64 = @intCast(FRAME_SIZE);
    const thresh = @max(@as(u64, 0x100000), @as(u64, @intCast(kernel_end)));
    const kernel_low_pfn_excl = (thresh + fs_u64 - 1) / fs_u64;

    const bitmap_begin = @intFromPtr(&fa.bitmap);
    const bitmap_bytes = BITMAP_SIZE * @sizeOf(u64);
    const bitmap_first = bitmap_begin & ~@as(usize, FRAME_SIZE - 1);
    const bitmap_past: usize = if (bitmap_begin > std.math.maxInt(usize) - bitmap_bytes)
        bitmap_first
    else
        std.mem.alignForward(usize, bitmap_begin + bitmap_bytes, FRAME_SIZE);

    const fl_begin = @intFromPtr(&fa.pfn_flink);
    const fl_bytes = MAX_PHYS_FRAMES * @sizeOf(u32) * 2 + MAX_PHYS_FRAMES * @sizeOf(u16);
    const fl_first = fl_begin & ~@as(usize, FRAME_SIZE - 1);
    const fl_past: usize = if (fl_begin > std.math.maxInt(usize) - fl_bytes)
        fl_first
    else
        std.mem.alignForward(usize, fl_begin + fl_bytes, FRAME_SIZE);

    return .{
        .kernel_low_pfn_excl = kernel_low_pfn_excl,
        .mb_active = fa.mb_handoff_end_exclusive > fa.mb_handoff_start,
        .mb_hs = @intCast(fa.mb_handoff_start),
        .mb_he = @intCast(fa.mb_handoff_end_exclusive),
        .bitmap_addr_first = @intCast(bitmap_first),
        .bitmap_addr_past = @intCast(bitmap_past),
        .pfn_tbl_addr_first = @intCast(fl_first),
        .pfn_tbl_addr_past = @intCast(fl_past),
        .fb_active = fa.fb_reserve_end_exclusive > fa.fb_reserve_start,
        .fb_start = fa.fb_reserve_start,
        .fb_end_excl = fa.fb_reserve_end_exclusive,
    };
}

fn isReservedBootSeed(frame: usize, c: *const BootSeedReservedCache) bool {
    if (frame >= MAX_PHYS_FRAMES) return true;
    const f: u64 = @intCast(frame);
    const fs_u64: u64 = @intCast(FRAME_SIZE);
    if (f > std.math.maxInt(u64) / fs_u64) return true;
    const addr = f * fs_u64;
    if (f < c.kernel_low_pfn_excl) return true;
    if (c.mb_active) {
        const past_ok = addr <= std.math.maxInt(u64) - fs_u64;
        if (addr < c.mb_he) {
            if (!past_ok) return true;
            if (addr + fs_u64 > c.mb_hs) return true;
        }
    }
    if (addr >= c.bitmap_addr_first and addr < c.bitmap_addr_past) return true;
    if (addr >= c.pfn_tbl_addr_first and addr < c.pfn_tbl_addr_past) return true;
    if (c.fb_active) {
        const page_after = addr +% fs_u64;
        if (page_after > addr and addr < c.fb_end_excl and page_after > c.fb_start)
            return true;
    }
    return false;
}

var frame_unit_test_storage: FrameAllocator = undefined;

test "frame zone dma vs normal" {
    frame_unit_test_storage.testSeedLinearFreeFrames(4096);
    const p = frame_unit_test_storage.allocInZone(.dma) orelse return error.Fail;
    try std.testing.expect(p < ZONE_DMA_PHYS_MAX);
    frame_unit_test_storage.free(p);
}

test "frame lock prevents free" {
    frame_unit_test_storage.testSeedLinearFreeFrames(256);
    const phys = frame_unit_test_storage.alloc() orelse return error.Fail;
    frame_unit_test_storage.lockPfnPhys(phys);
    frame_unit_test_storage.free(phys);
    try std.testing.expect(!frame_unit_test_storage.isPhysicalPageFree(phys));
    frame_unit_test_storage.unlockPfnPhys(phys);
    frame_unit_test_storage.free(phys);
    try std.testing.expect(frame_unit_test_storage.isPhysicalPageFree(phys));
}

test "frame freeContiguousRange" {
    frame_unit_test_storage.testSeedLinearFreeFrames(64);
    const base = frame_unit_test_storage.allocContiguous(4) orelse return error.Fail;
    frame_unit_test_storage.freeContiguousRange(base, 4);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try std.testing.expect(frame_unit_test_storage.isPhysicalPageFree(base + @as(u64, @intCast(i * FRAME_SIZE))));
    }
}

test "pfn allocZeroed prefers zeroed list" {
    frame_unit_test_storage.testSeedLinearFreeFrames(64);
    frame_unit_test_storage.testEnqueueZeroedFrame(10);
    const p = frame_unit_test_storage.allocZeroed() orelse return error.Fail;
    try std.testing.expectEqual(@as(u64, 10 * FRAME_SIZE), p);
    frame_unit_test_storage.free(p);
}

test "pfn share count blocks free" {
    frame_unit_test_storage.testSeedLinearFreeFrames(32);
    const p = frame_unit_test_storage.alloc() orelse return error.Fail;
    frame_unit_test_storage.notePageShared(p);
    frame_unit_test_storage.free(p);
    try std.testing.expect(!frame_unit_test_storage.isPhysicalPageFree(p));
    frame_unit_test_storage.releaseShareCount(p);
    frame_unit_test_storage.free(p);
    try std.testing.expect(frame_unit_test_storage.isPhysicalPageFree(p));
}

test "mergePhysSpans merges overlap" {
    var raw: [4]MmapPhysSpan = undefined;
    raw[0] = .{ .start = 0x1000, .end_excl = 0x3000 };
    raw[1] = .{ .start = 0x2000, .end_excl = 0x4000 };
    sortPhysSpans(raw[0..2]);
    var out: [4]MmapPhysSpan = undefined;
    const n = mergePhysSpans(raw[0..2], &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 0x1000), out[0].start);
    try std.testing.expectEqual(@as(u64, 0x4000), out[0].end_excl);
}

test "subtractNonRamFromRange splits and skips holes" {
    const holes = [_]MmapPhysSpan{
        .{ .start = 0x2000, .end_excl = 0x3000 },
        .{ .start = 0x5000, .end_excl = 0x6000 },
    };
    var out: [4]MmapPhysSpan = undefined;
    const n = subtractNonRamFromRange(0x1000, 0x7000, &holes, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u64, 0x1000), out[0].start);
    try std.testing.expectEqual(@as(u64, 0x2000), out[0].end_excl);
    try std.testing.expectEqual(@as(u64, 0x3000), out[1].start);
    try std.testing.expectEqual(@as(u64, 0x5000), out[1].end_excl);
    try std.testing.expectEqual(@as(u64, 0x6000), out[2].start);
    try std.testing.expectEqual(@as(u64, 0x7000), out[2].end_excl);
}

test "allocZeroedBelowMaxPhys low PFN" {
    frame_unit_test_storage.testSeedLinearFreeFrames(256);
    // 主机上 `memsetPhysicalPage` 非 freestanding 路径会把 GPA 当 VA；用零页链满足分配，避免真写物理低址。
    frame_unit_test_storage.testEnqueueZeroedFrame(5);
    const p = frame_unit_test_storage.allocZeroedBelowMaxPhys(32 * FRAME_SIZE) orelse return error.Fail;
    try std.testing.expectEqual(@as(u64, 5 * FRAME_SIZE), p);
    frame_unit_test_storage.free(p);
}

test "testSeed total_frames matches enqueued pages" {
    frame_unit_test_storage.testSeedLinearFreeFrames(100);
    try std.testing.expectEqual(@as(usize, 100), frame_unit_test_storage.total_frames);
}
