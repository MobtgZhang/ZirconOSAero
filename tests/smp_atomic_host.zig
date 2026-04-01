// SPDX-License-Identifier: MIT OR Apache-2.0
// Host-only: documents SMP stress pattern (atomic increment); run via `zig build test`.
const std = @import("std");

test "SMP-style atomic counter sanity" {
    var v = std.atomic.Value(u64).init(0);
    _ = v.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u64, 1), v.load(.monotonic));
}
