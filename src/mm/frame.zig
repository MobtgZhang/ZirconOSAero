//! Physical Frame Allocator
//! Bitmap-based management of available physical pages + Zone 偏好 + 最简 PFN 元数据（K1.1）。
//! NT style: kernel provides physical memory allocation mechanism
//!
//! Ref: Multiboot2 memory map; OS textbook free-list / bitmap; Intel SDM physical addressing.
//! Physical span tracked: `build.zig -Dphys_track_gb=8|16|32|64` → `build_options.phys_track_gb` (default 8).

const std = @import("std");
const arch = @import("../arch.zig");
const boot_mod = arch.impl.boot;
const build_cfg = @import("build_options");

pub const FRAME_SIZE: usize = arch.PAGE_SIZE;

/// 按字节清零一帧；避免 `ptr[0..FRAME_SIZE]` 在 Debug 下对 slice 末端地址做溢出检查触发误报 panic。
/// 地址须为 `FrameAllocator` 给出的合法 GPA（本模块 PFN 上界内）；`+%` 仅用于抑制编译器对 `phys+i` 的断言。
pub fn memsetPhysicalPage(phys: u64) void {
    var i: usize = 0;
    while (i < FRAME_SIZE) : (i += 1) {
        (@as(*volatile u8, @ptrFromInt(phys +% @as(u64, @intCast(i))))).* = 0;
    }
}

/// 可跟踪的最大 PFN，由构建选项 `phys_track_gb` 决定（8/16/32/64 GiB）；高于此的 mmap 区间在启动时忽略。
/// BSS 成本随 `phys_track_gb` 线性增长：`bitmap` + `pfn_meta` + `pfn_locks`。
pub const MAX_PHYS_FRAMES: usize = @as(usize, @intCast(build_cfg.phys_track_gb)) * (1024 * 1024 * 1024) / FRAME_SIZE;
pub const BITMAP_SIZE: usize = (MAX_PHYS_FRAMES + 63) / 64;

/// DMA：物理地址 &lt; 16MiB（ISA DMA 文档习惯上界）。
pub const ZONE_DMA_PHYS_MAX: u64 = 16 * 1024 * 1024;
/// Normal：物理地址 &lt; 4GiB（32 位 DMA / 常见设备窗口）。
pub const ZONE_NORMAL_PHYS_MAX: u64 = 0x1_0000_0000;

pub const MemoryZone = enum(u8) {
    dma,
    normal,
    high,
};

/// 与位图同步的最简 PFN 状态（换出/COW 前置）。
pub const PfnState = enum(u8) {
    unused = 0,
    free = 1,
    active = 2,
    zeroed = 3,
    reserved = 4,
    buddy_arena = 5,
    /// 分页池「可换出」占位（当前未实现换出；供 WDK 语义对齐与调试断言）。
    standby = 6,
};

/// 供帧缓冲大后备区等路径按需申请连续物理页（如 `framebuffer.init`）。
pub var kernel_frame_alloc: ?*FrameAllocator = null;

/// 全局内核帧分配器存储（避免超大 `FrameAllocator` 驻留在启动栈上）。
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

fn frameIndexInZone(frame: usize, zone: MemoryZone) bool {
    const phys = @as(u64, @intCast(frame)) * @as(u64, @intCast(FRAME_SIZE));
    return zoneForPhysAddr(phys) == zone;
}

pub const FrameAllocator = struct {
    bitmap: [BITMAP_SIZE]u64,
    pfn_meta: [MAX_PHYS_FRAMES]u8,
    pfn_locks: [MAX_PHYS_FRAMES]u8,
    total_frames: usize,
    used_frames: usize,
    mb_handoff_start: usize = 0,
    mb_handoff_end_exclusive: usize = 0,

    pub fn init(self: *FrameAllocator, boot_info: ?boot_mod.BootInfo, kernel_end: usize) void {
        for (&self.bitmap) |*b| b.* = 0;
        @memset(&self.pfn_meta, @intFromEnum(PfnState.unused));
        @memset(&self.pfn_locks, 0);
        self.total_frames = 0;
        self.used_frames = 0;
        self.mb_handoff_start = 0;
        self.mb_handoff_end_exclusive = 0;

        const info = boot_info orelse return;

        if (info.multiboot_handoff_end_exclusive > info.multiboot_handoff_start) {
            self.mb_handoff_start = info.multiboot_handoff_start;
            self.mb_handoff_end_exclusive = info.multiboot_handoff_end_exclusive;
        }

        // Multiboot2 EFI mmap: only type `available` (1) is added to the free bitmap.
        // Types reserved(2), acpi_reclaimable(3), nvs(4), bad(5) must never be handed to the allocator
        // (ACPI NVS / firmware reserved — see UEFI/ACPI platform docs; clean-room, no Windows source).
        var i: usize = 0;
        while (i < info.mmap_entry_count) : (i += 1) {
            const entry = info.getMmapEntry(i) orelse break;
            if (entry.type != @intFromEnum(boot_mod.MmapEntryType.available)) continue;
            if (entry.length == 0) continue;

            const base = entry.base_addr;
            const len = entry.length;
            // UEFI/固件可能给出畸形条目，`base + len` 在 u64 上溢出会在 Debug 内核中触发 integer overflow panic。
            if (base > std.math.maxInt(u64) - len) continue;
            const end_exclusive = base + len;
            const start_frame = base / FRAME_SIZE;
            const end_frame = end_exclusive / FRAME_SIZE;

            var f = start_frame;
            while (f < end_frame and f < MAX_PHYS_FRAMES) : (f += 1) {
                if (self.isReserved(f, kernel_end)) continue;
                self.setFree(@as(usize, @intCast(f)));
                self.total_frames += 1;
            }
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
            if (addr < he and !past_ok) return true; // addr+页大小溢出，保守视为与 handoff 重叠
        }
        const bitmap_begin = @intFromPtr(&self.bitmap);
        const bitmap_bytes = BITMAP_SIZE * @sizeOf(u64);
        const bitmap_first = bitmap_begin & ~@as(usize, FRAME_SIZE - 1);
        if (bitmap_begin > std.math.maxInt(usize) - bitmap_bytes) return true;
        const bitmap_past = std.mem.alignForward(usize, bitmap_begin + bitmap_bytes, FRAME_SIZE);
        if (addr >= bitmap_first and addr < bitmap_past) return true;
        return false;
    }

    fn setPfn(self: *FrameAllocator, frame: usize, st: PfnState) void {
        if (frame < MAX_PHYS_FRAMES) self.pfn_meta[frame] = @intFromEnum(st);
    }

    fn getPfn(self: *const FrameAllocator, frame: usize) PfnState {
        if (frame >= MAX_PHYS_FRAMES) return .unused;
        return @enumFromInt(self.pfn_meta[frame]);
    }

    fn setFree(self: *FrameAllocator, frame: usize) void {
        const word = frame / 64;
        const bit = frame % 64;
        if (word < BITMAP_SIZE) {
            self.bitmap[word] |= @as(u64, 1) << @intCast(bit);
        }
        self.setPfn(frame, .free);
    }

    fn isFree(self: *const FrameAllocator, frame: usize) bool {
        const word = frame / 64;
        const bit = frame % 64;
        if (word >= BITMAP_SIZE) return false;
        return (self.bitmap[word] & (@as(u64, 1) << @intCast(bit))) != 0;
    }

    fn setUsed(self: *FrameAllocator, frame: usize) void {
        const word = frame / 64;
        const bit = frame % 64;
        if (word < BITMAP_SIZE) {
            self.bitmap[word] &= ~(@as(u64, 1) << @intCast(bit));
        }
        self.setPfn(frame, .active);
    }

    /// 伙伴 arena 等已占用但非「活跃匿名页」的帧。
    pub fn markBuddyArenaFrames(self: *FrameAllocator, phys_start: u64, num_pages: usize) void {
        var i: usize = 0;
        while (i < num_pages) : (i += 1) {
            const step = @as(u64, @intCast(i)) * @as(u64, @intCast(FRAME_SIZE));
            if (phys_start > std.math.maxInt(u64) - step) break;
            const phys = phys_start + step;
            const fr: usize = @intCast(phys / FRAME_SIZE);
            if (fr < MAX_PHYS_FRAMES) self.setPfn(fr, .buddy_arena);
        }
    }

    pub fn pfnState(self: *const FrameAllocator, phys: u64) PfnState {
        const fr: usize = @intCast(phys / FRAME_SIZE);
        return self.getPfn(fr);
    }

    /// MDL / 锁页：`refcount` 次 `unlockPfnPhys` 后才可参与 `free`。
    pub fn lockPfnPhys(self: *FrameAllocator, phys: u64) void {
        const fr: usize = @intCast(phys / FRAME_SIZE);
        if (fr >= MAX_PHYS_FRAMES) return;
        if (self.pfn_locks[fr] < 255) self.pfn_locks[fr] += 1;
    }

    pub fn unlockPfnPhys(self: *FrameAllocator, phys: u64) void {
        const fr: usize = @intCast(phys / FRAME_SIZE);
        if (fr >= MAX_PHYS_FRAMES) return;
        if (self.pfn_locks[fr] > 0) self.pfn_locks[fr] -= 1;
    }

    pub fn pfnLockCount(self: *const FrameAllocator, phys: u64) u8 {
        const fr: usize = @intCast(phys / FRAME_SIZE);
        if (fr >= MAX_PHYS_FRAMES) return 0;
        return self.pfn_locks[fr];
    }

    fn tryAllocFrame(self: *FrameAllocator, frame: usize) ?u64 {
        if (frame >= MAX_PHYS_FRAMES) return null;
        if (!self.isFree(frame)) return null;
        if (self.pfn_locks[frame] != 0) return null;
        self.setUsed(frame);
        self.used_frames += 1;
        return @as(u64, @intCast(frame * FRAME_SIZE));
    }

    /// 默认：优先 normal，其次 high，最后 dma（保留低 16MiB 给需要 ZONE_DMA 的调用方）。
    pub fn alloc(self: *FrameAllocator) ?u64 {
        if (self.allocInZone(.normal)) |p| return p;
        if (self.allocInZone(.high)) |p| return p;
        return self.allocInZone(.dma);
    }

    /// 自 `<16MiB` 区间取一页（AC97 等 DMA）。
    pub fn allocDma(self: *FrameAllocator) ?u64 {
        return self.allocInZone(.dma);
    }

    pub fn allocInZone(self: *FrameAllocator, zone: MemoryZone) ?u64 {
        var word: usize = 0;
        while (word < BITMAP_SIZE) : (word += 1) {
            var bits = self.bitmap[word];
            while (bits != 0) {
                const trailing = @ctz(bits);
                const frame = word * 64 + trailing;
                if (frame >= MAX_PHYS_FRAMES) break;
                if (frameIndexInZone(frame, zone)) {
                    if (self.tryAllocFrame(frame)) |p| return p;
                }
                bits &= ~(@as(u64, 1) << @intCast(trailing));
            }
        }
        return null;
    }

    pub fn isPhysicalPageFree(self: *const FrameAllocator, phys: u64) bool {
        const fr: usize = @intCast(phys / FRAME_SIZE);
        return self.isFree(fr);
    }

    pub fn free(self: *FrameAllocator, phys: u64) void {
        const frame = phys / FRAME_SIZE;
        if (frame >= MAX_PHYS_FRAMES) return;
        // MDL / `lockPfnPhys`：锁计数非零时禁止归还帧，避免 DMA 或锁页窗口与空闲链表竞态（WDK 锁页语义子集）。
        if (self.pfn_locks[@intCast(frame)] != 0) return;
        self.setFree(@as(usize, @intCast(frame)));
        if (self.used_frames > 0) self.used_frames -= 1;
    }

    pub fn allocZeroed(self: *FrameAllocator) ?u64 {
        const phys = self.alloc() orelse return null;
        memsetPhysicalPage(phys);
        const fr: usize = @intCast(phys / FRAME_SIZE);
        if (fr < MAX_PHYS_FRAMES) self.setPfn(fr, .zeroed);
        return phys;
    }

    /// 分配 `num_frames` 个**连续**空闲物理页；`zone_hint` 为首选区域，失败时按 normal→high→dma 回退。
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
            if (!frameIndexInZone(start, zone)) continue;
            if (!frameIndexInZone(start + num_frames - 1, zone)) continue;
            var all_free = true;
            var i: usize = 0;
            while (i < num_frames) : (i += 1) {
                if (!self.isFree(start + i) or self.pfn_locks[start + i] != 0) {
                    all_free = false;
                    break;
                }
            }
            if (!all_free) continue;
            i = 0;
            while (i < num_frames) : (i += 1) {
                self.setUsed(start + i);
            }
            self.used_frames += num_frames;
            return @as(u64, @intCast(start * FRAME_SIZE));
        }
        return null;
    }

    /// 释放 `allocContiguous` / `allocContiguousInZone` 得到的连续 `num_pages` 页（自 `phys_start` 起）。
    pub fn freeContiguousRange(self: *FrameAllocator, phys_start: u64, num_pages: usize) void {
        var i: usize = 0;
        while (i < num_pages) : (i += 1) {
            const step = @as(u64, @intCast(i)) * @as(u64, @intCast(FRAME_SIZE));
            if (phys_start > std.math.maxInt(u64) - step) break;
            self.free(phys_start + step);
        }
    }

    /// 将 `[phys_start, phys_start + byte_len)` 内已在位图中标为「空闲」的页改为已用（如 QEMU ramfb 固定物理区）。
    pub fn markPhysRangeUsed(self: *FrameAllocator, phys_start: usize, byte_len: usize) void {
        if (byte_len == 0) return;
        if (phys_start > std.math.maxInt(usize) - byte_len) return;
        const ps = FRAME_SIZE;
        var addr = phys_start & ~(ps - 1);
        const end = phys_start + byte_len;
        while (addr < end) {
            const frame_idx: usize = addr / ps;
            if (frame_idx >= MAX_PHYS_FRAMES) break;
            if (self.isFree(frame_idx)) {
                self.setUsed(frame_idx);
                self.used_frames += 1;
            }
            if (addr > std.math.maxInt(usize) - ps) break;
            addr += ps;
        }
    }

    /// **单元测试专用**：将帧号 `0..num_frames` 标为可用（不经 multiboot）；勿在生产内核调用。
    pub fn testSeedLinearFreeFrames(self: *FrameAllocator, num_frames: usize) void {
        for (&self.bitmap) |*w| w.* = 0;
        @memset(&self.pfn_meta, @intFromEnum(PfnState.unused));
        @memset(&self.pfn_locks, 0);
        self.total_frames = num_frames;
        self.used_frames = 0;
        self.mb_handoff_start = 0;
        self.mb_handoff_end_exclusive = 0;
        var f: usize = 0;
        while (f < num_frames and f < MAX_PHYS_FRAMES) : (f += 1) {
            self.setFree(f);
        }
    }
};

// `FrameAllocator` 在 8GiB 跟踪下体积大，勿在测试栈上分配。
var frame_unit_test_storage: FrameAllocator = undefined;

test "frame zone dma vs normal" {
    frame_unit_test_storage.testSeedLinearFreeFrames(4096); // 16MiB worth
    const p = frame_unit_test_storage.allocInZone(.dma) orelse return error.Fail;
    try std.testing.expect(p < ZONE_DMA_PHYS_MAX);
    frame_unit_test_storage.free(p);
}

test "frame lock prevents free" {
    frame_unit_test_storage.testSeedLinearFreeFrames(256);
    const phys = frame_unit_test_storage.alloc() orelse return error.Fail;
    frame_unit_test_storage.lockPfnPhys(phys);
    frame_unit_test_storage.free(phys); // should not free while locked
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
