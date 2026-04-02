// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/msg_pm_semantics.zig
// Purpose: `PeekMessage` `wRemoveMsg` 标志的纯函数语义（主机可测，无内核依赖）。
//
// This is an independent clean-room implementation.
// Reference: https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-peekmessagea (`wRemoveMsg`)

const std = @import("std");

pub const PM_NOREMOVE: u32 = 0x0000;
pub const PM_REMOVE: u32 = 0x0001;
pub const PM_NOYIELD: u32 = 0x0002;

/// `PM_NOREMOVE` 数值为 0：从队列取消息但不移除 = 未设置 `PM_REMOVE`。
pub fn removeMsgFromQueueOnPeek(remove_flags: u32) bool {
    return (remove_flags & PM_REMOVE) != 0;
}

/// `PM_NOYIELD` 置位时，有让出语义的 API 不应为其他线程轮转调度器。
pub fn allowSchedulerYieldForPeekFlags(remove_flags: u32) bool {
    return (remove_flags & PM_NOYIELD) == 0;
}

/// 与 `user32.msgMatchesFilter` 一致：`min==0 && max==0` 表示不过滤；否则 `message` 落在闭区间 `[min,max]`。
pub fn messageMatchesMinMaxFilter(message: u32, min: u32, max: u32) bool {
    if (min == 0 and max == 0) return true;
    return message >= min and message <= max;
}

test "PM_REMOVE vs default (NOREMOVE)" {
    try std.testing.expect(!removeMsgFromQueueOnPeek(0));
    try std.testing.expect(!removeMsgFromQueueOnPeek(PM_NOREMOVE));
    try std.testing.expect(removeMsgFromQueueOnPeek(PM_REMOVE));
    try std.testing.expect(removeMsgFromQueueOnPeek(PM_REMOVE | PM_NOYIELD));
}

test "PM_NOYIELD suppresses yield allowance" {
    try std.testing.expect(allowSchedulerYieldForPeekFlags(0));
    try std.testing.expect(allowSchedulerYieldForPeekFlags(PM_REMOVE));
    try std.testing.expect(!allowSchedulerYieldForPeekFlags(PM_NOYIELD));
    try std.testing.expect(!allowSchedulerYieldForPeekFlags(PM_REMOVE | PM_NOYIELD));
}

test "PM_REMOVE combined bitmask" {
    try std.testing.expectEqual(@as(u32, 3), PM_REMOVE | PM_NOYIELD);
    try std.testing.expect(removeMsgFromQueueOnPeek(PM_REMOVE | PM_NOYIELD));
}

// GetMessage / PeekMessage 的 min/max 过滤与阻塞语义见 user32.zig；此处仅 PM_* 位标志锚点（契约矩阵 §5）。
test "peek remove flags documented band" {
    try std.testing.expect(PM_NOREMOVE < PM_REMOVE);
}

test "min max filter: zero zero is wildcard" {
    try std.testing.expect(messageMatchesMinMaxFilter(0x0201, 0, 0));
    try std.testing.expect(messageMatchesMinMaxFilter(0, 0, 0));
}

test "min max filter: inclusive range" {
    try std.testing.expect(messageMatchesMinMaxFilter(5, 1, 10));
    try std.testing.expect(!messageMatchesMinMaxFilter(0, 1, 10));
    try std.testing.expect(!messageMatchesMinMaxFilter(11, 1, 10));
}

test "min max filter: single message" {
    try std.testing.expect(messageMatchesMinMaxFilter(0x031E, 0x031E, 0x031E));
    try std.testing.expect(!messageMatchesMinMaxFilter(0x031D, 0x031E, 0x031E));
}

/// `min==0 && max==0` 为 Learn 常见「不过滤」；否则要求 `min <= max`（畸形范围由调用方拒绝）。
pub fn minMaxRangeWellFormed(min: u32, max: u32) bool {
    if (min == 0 and max == 0) return true;
    return min <= max;
}

test "min max well-formed" {
    try std.testing.expect(minMaxRangeWellFormed(0, 0));
    try std.testing.expect(minMaxRangeWellFormed(1, 10));
    try std.testing.expect(!minMaxRangeWellFormed(10, 1));
}

// ── GetMessage / PeekMessage 与 Learn 的差距表（问题四 / 矩阵 §5）────────────────
// | 主题 | Learn 期望（摘要） | 本仓库 `user32` 当前行为 |
// |------|-------------------|---------------------------|
// | `PeekMessage` PM_REMOVE | 置位时从队列移除 | `Window.peekMessage` / 过滤路径一致；纯函数标志见上 |
// | `PeekMessage` PM_NOYIELD | 置位时不应主动让出调度 | 多线程下仍可能 `blockThread`；以 `allowSchedulerYieldForPeekFlags` 为契约锚点 |
// | `GetMessage` 阻塞 | 无消息时阻塞至有消息或 WM_QUIT | 协作式：`STATUS_PENDING` + `blockThread`；与真 NT 抢占差异见 syscall 注释 |
// | 过滤范围 min/max | 仅返回区间内消息 | `getMessageFiltered` 轮转放回非匹配消息（简化语义）；纯函数镜像见 `messageMatchesMinMaxFilter` |
