// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/display_flip_journal.zig
// Purpose: Present-generation counter + idle-tail input poll budgeting (Phase B1/D5 hook).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/learnwin32/the-desktop-window-manager (composition pacing concepts)

const std = @import("std");

var present_generation: u64 = 0;

/// Incremented after each successful `present()` flip path (full or dirty).
pub fn notePresentFlip() void {
    present_generation +%= 1;
}

pub fn getPresentGeneration() u64 {
    return present_generation;
}

/// When the desktop loop has not painted for many iterations, reduce redundant `input_hub` polls
/// slightly to lower guest CPU use while keeping a minimum floor for responsiveness.
pub fn extraInputPollBudget(default_polls: u32, idle_streak: u32) u32 {
    if (idle_streak < 24) return default_polls;
    const half = default_polls / 2;
    return @max(half, 4);
}

test "extraInputPollBudget respects floor" {
    try std.testing.expectEqual(@as(u32, 16), extraInputPollBudget(16, 0));
    try std.testing.expectEqual(@as(u32, 8), extraInputPollBudget(16, 30));
    try std.testing.expectEqual(@as(u32, 4), extraInputPollBudget(6, 30));
}
