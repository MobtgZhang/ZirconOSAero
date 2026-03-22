//! Physical Frame Allocator
//! Bitmap-based management of available physical pages
//! NT style: kernel provides physical memory allocation mechanism

const arch = @import("../arch.zig");
const boot_mod = arch.impl.boot;

pub const FRAME_SIZE: usize = arch.PAGE_SIZE;

const MAX_PHYS_FRAMES: usize = 262144; // 1GB / 4KB
const BITMAP_SIZE: usize = (MAX_PHYS_FRAMES + 63) / 64;

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

    fn isReserved(self: *FrameAllocator, frame: u64, kernel_end: usize, mbi_phys: usize) bool {
        const addr = frame * FRAME_SIZE;
        if (addr < 0x100000) return true;
        if (addr < kernel_end) return true;
        const mbi_page = mbi_phys & ~(FRAME_SIZE - 1);
        if (addr >= mbi_page and addr < mbi_page + FRAME_SIZE) return true;
        const bitmap_addr = @intFromPtr(&self.bitmap);
        const bitmap_page = bitmap_addr & ~(FRAME_SIZE - 1);
        if (addr >= bitmap_page and addr < bitmap_page + FRAME_SIZE) return true;
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
        const ptr = @as(*[1024]u32, @ptrFromInt(phys));
        for (ptr) |*p| p.* = 0;
        return phys;
    }
};
