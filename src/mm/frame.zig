//! Physical Frame Allocator
//! Bitmap-based management of available physical pages
//! NT style: kernel provides physical memory allocation mechanism

const std = @import("std");
const arch = @import("../arch.zig");
const boot_mod = arch.impl.boot;

pub const FRAME_SIZE: usize = arch.PAGE_SIZE;

/// 物理页号上限（QEMU AArch64/RISC-V 等 RAM 常在 0x4000_0000 / 0x8000_0000 之后，须覆盖 ≥4GB 线性地址空间）
const MAX_PHYS_FRAMES: usize = 1048576; // 4GiB / 4KiB
const BITMAP_SIZE: usize = (MAX_PHYS_FRAMES + 63) / 64;

/// 供帧缓冲大后备区等路径按需申请连续物理页（如 `framebuffer.init`）。
pub var kernel_frame_alloc: ?*FrameAllocator = null;

pub fn setKernelFrameAllocator(a: ?*FrameAllocator) void {
    kernel_frame_alloc = a;
}

pub fn getKernelFrameAllocator() ?*FrameAllocator {
    return kernel_frame_alloc;
}

pub const FrameAllocator = struct {
    bitmap: [BITMAP_SIZE]u64,
    total_frames: usize,
    used_frames: usize,
    mb_handoff_start: usize = 0,
    mb_handoff_end_exclusive: usize = 0,

    pub fn init(self: *FrameAllocator, boot_info: ?boot_mod.BootInfo, kernel_end: usize) void {
        for (&self.bitmap) |*b| b.* = 0;
        self.total_frames = 0;
        self.used_frames = 0;
        self.mb_handoff_start = 0;
        self.mb_handoff_end_exclusive = 0;

        const info = boot_info orelse return;

        if (info.multiboot_handoff_end_exclusive > info.multiboot_handoff_start) {
            self.mb_handoff_start = info.multiboot_handoff_start;
            self.mb_handoff_end_exclusive = info.multiboot_handoff_end_exclusive;
        }

        var i: usize = 0;
        while (i < info.mmap_entry_count) : (i += 1) {
            const entry = info.getMmapEntry(i) orelse break;
            if (entry.type != @intFromEnum(boot_mod.MmapEntryType.available)) continue;
            if (entry.length == 0) continue;

            const base = entry.base_addr;
            const len = entry.length;
            const start_frame = base / FRAME_SIZE;
            const end_frame = (base + len) / FRAME_SIZE;

            var f = start_frame;
            while (f < end_frame and f < MAX_PHYS_FRAMES) : (f += 1) {
                if (self.isReserved(f, kernel_end)) continue;
                self.setFree(@as(usize, @intCast(f)));
                self.total_frames += 1;
            }
        }
    }

    fn isReserved(self: *FrameAllocator, frame: u64, kernel_end: usize) bool {
        const addr = frame * FRAME_SIZE;
        if (addr < 0x100000) return true;
        if (addr < kernel_end) return true;
        if (self.mb_handoff_end_exclusive > self.mb_handoff_start) {
            const hs = self.mb_handoff_start;
            const he = self.mb_handoff_end_exclusive;
            if (addr < he and addr + FRAME_SIZE > hs) return true;
        }
        // bitmap 跨多页（16KB 页上约 8 页）；仅保留首帧会导致其余 bitmap 页被 alloc 复用，位图损坏后在 identity map 约 8MB 处失败。
        const bitmap_begin = @intFromPtr(&self.bitmap);
        const bitmap_bytes = BITMAP_SIZE * @sizeOf(u64);
        const bitmap_first = bitmap_begin & ~@as(usize, FRAME_SIZE - 1);
        const bitmap_past = std.mem.alignForward(usize, bitmap_begin + bitmap_bytes, FRAME_SIZE);
        if (addr >= bitmap_first and addr < bitmap_past) return true;
        return false;
    }

    fn setFree(self: *FrameAllocator, frame: usize) void {
        const word = frame / 64;
        const bit = frame % 64;
        if (word < BITMAP_SIZE) {
            self.bitmap[word] |= @as(u64, 1) << @intCast(bit);
        }
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
    }

    pub fn alloc(self: *FrameAllocator) ?u64 {
        var word: usize = 0;
        while (word < BITMAP_SIZE) : (word += 1) {
            const bits = self.bitmap[word];
            if (bits == 0) continue;
            const trailing = @ctz(bits);
            const frame = word * 64 + trailing;
            if (frame >= MAX_PHYS_FRAMES) break;
            self.setUsed(frame);
            self.used_frames += 1;
            return frame * FRAME_SIZE;
        }
        return null;
    }

    pub fn free(self: *FrameAllocator, phys: u64) void {
        const frame = phys / FRAME_SIZE;
        if (frame >= MAX_PHYS_FRAMES) return;
        self.setFree(@as(usize, @intCast(frame)));
        if (self.used_frames > 0) self.used_frames -= 1;
    }

    pub fn allocZeroed(self: *FrameAllocator) ?u64 {
        const phys = self.alloc() orelse return null;
        const ptr: [*]align(1) u8 = @ptrFromInt(phys);
        @memset(ptr[0..FRAME_SIZE], 0);
        return phys;
    }

    /// 分配 `num_frames` 个**连续**空闲物理页，首地址按 `FRAME_SIZE` 对齐。
    pub fn allocContiguous(self: *FrameAllocator, num_frames: usize) ?u64 {
        if (num_frames == 0) return null;
        const limit: usize = MAX_PHYS_FRAMES - num_frames;
        var start: usize = 0;
        while (start <= limit) : (start += 1) {
            var all_free = true;
            var i: usize = 0;
            while (i < num_frames) : (i += 1) {
                if (!self.isFree(start + i)) {
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

    /// 将 `[phys_start, phys_start + byte_len)` 内已在位图中标为「空闲」的页改为已用（如 QEMU ramfb 固定物理区）。
    pub fn markPhysRangeUsed(self: *FrameAllocator, phys_start: usize, byte_len: usize) void {
        if (byte_len == 0) return;
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
            addr += ps;
        }
    }

    /// **单元测试专用**：将帧号 `0..num_frames` 标为可用（不经 multiboot）；勿在生产内核调用。
    pub fn testSeedLinearFreeFrames(self: *FrameAllocator, num_frames: usize) void {
        for (&self.bitmap) |*w| w.* = 0;
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
