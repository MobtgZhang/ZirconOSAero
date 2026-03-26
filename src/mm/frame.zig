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

    pub fn init(self: *FrameAllocator, boot_info: ?boot_mod.BootInfo, kernel_end: usize, mbi_phys: usize) void {
        for (&self.bitmap) |*b| b.* = 0;
        self.total_frames = 0;
        self.used_frames = 0;

        const info = boot_info orelse return;

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
                if (self.isReserved(f, kernel_end, mbi_phys)) continue;
                self.setFree(@as(usize, @intCast(f)));
                self.total_frames += 1;
            }
        }
    }

    /// Multiboot2 信息块首字段为 `total_size`（字节）；保留 `[mbi_phys, …)` 向上取整到页，避免 ZBM 多页 MBI 被帧分配器覆盖。
    fn multibootReservedEndExclusive(mbi_phys: usize) usize {
        const hdr: *align(1) const volatile u32 = @ptrFromInt(mbi_phys);
        var total: usize = hdr.*;
        if (total < 8) total = 8;
        const max_total: usize = 16 * 1024 * 1024;
        if (total > max_total) total = max_total;
        return mbi_phys + std.mem.alignForward(usize, total, FRAME_SIZE);
    }

    fn isReserved(self: *FrameAllocator, frame: u64, kernel_end: usize, mbi_phys: usize) bool {
        const addr = frame * FRAME_SIZE;
        if (addr < 0x100000) return true;
        if (addr < kernel_end) return true;
        if (mbi_phys != 0) {
            const end_excl = multibootReservedEndExclusive(mbi_phys);
            if (addr < end_excl and addr + FRAME_SIZE > mbi_phys) return true;
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
};
