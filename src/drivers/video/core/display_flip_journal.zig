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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/core/display_flip_journal.zig
// Purpose: Present-generation counter + idle-tail input poll budgeting (Phase B1/D5 hook).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/learnwin32/the-desktop-window-manager (composition pacing concepts)

const std = @import("std");

var present_generation: u64 = 0;
var virtio_resource_flush_full: u64 = 0;
var virtio_resource_flush_partial: u64 = 0;
/// 单次 `present` 内发出的 `RESOURCE_FLUSH` 操作累计（多资源策略预留；当前主路径为 1）。
var virtio_present_flush_ops_total: u64 = 0;

/// Incremented after each successful `present()` flip path (full or dirty).
pub fn notePresentFlip() void {
    present_generation +%= 1;
}

pub fn getPresentGeneration() u64 {
    return present_generation;
}

/// `virtio_gpu_pci.notifyScanoutFrontUpdated` 遥测：整幅 vs 脏矩形 `RESOURCE_FLUSH`。
pub fn noteVirtioResourceFlush(is_full_screen: bool) void {
    if (is_full_screen) {
        virtio_resource_flush_full +%= 1;
    } else {
        virtio_resource_flush_partial +%= 1;
    }
}

/// 记录本帧 `present` 路径上执行的 flush 次数（单 scanout 资源为 1；未来 overlay 资源可 >1）。
pub fn noteVirtioPresentFlushBatch(resource_flush_count: u32) void {
    if (resource_flush_count == 0) return;
    virtio_present_flush_ops_total +%= resource_flush_count;
}

pub fn getVirtioFlushTelemetry() struct { full: u64, partial: u64 } {
    return .{ .full = virtio_resource_flush_full, .partial = virtio_resource_flush_partial };
}

pub fn getVirtioPresentFlushOpsTotal() u64 {
    return virtio_present_flush_ops_total;
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

test "noteVirtioResourceFlush increments telemetry" {
    const b0 = getVirtioFlushTelemetry();
    noteVirtioResourceFlush(true);
    const b1 = getVirtioFlushTelemetry();
    try std.testing.expect(b1.full >= b0.full + 1);
    noteVirtioResourceFlush(false);
    const b2 = getVirtioFlushTelemetry();
    try std.testing.expect(b2.partial >= b1.partial + 1);
}

test "noteVirtioPresentFlushBatch accumulates ops" {
    const t0 = getVirtioPresentFlushOpsTotal();
    noteVirtioPresentFlushBatch(1);
    noteVirtioPresentFlushBatch(2);
    try std.testing.expectEqual(t0 + 3, getVirtioPresentFlushOpsTotal());
}
