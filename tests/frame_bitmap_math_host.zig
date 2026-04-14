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
