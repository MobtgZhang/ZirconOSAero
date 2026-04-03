//! Host-only: bitmap/PFN array sizing invariants for physical frame tracking (mirrors `src/mm/frame.zig`).
const std = @import("std");

test "frame bitmap words cover MAX_PHYS_FRAMES for common phys_track_gb" {
    const page: usize = 4096;
    inline for ([_]u32{ 8, 16, 32, 64 }) |gb| {
        const max_frames = @as(usize, @intCast(gb)) * (1024 * 1024 * 1024) / page;
        const bitmap_words = (max_frames + 63) / 64;
        try std.testing.expect(max_frames > 0);
        try std.testing.expect(bitmap_words * 64 >= max_frames);
    }
}
