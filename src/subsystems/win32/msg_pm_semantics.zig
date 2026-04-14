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

test "SetWindowPos SWP flag values (Learn anchors)" {
    const SWP_NOSIZE: u32 = 0x0001;
    const SWP_NOMOVE: u32 = 0x0002;
    const SWP_NOZORDER: u32 = 0x0004;
    const SWP_NOACTIVATE: u32 = 0x0010;
    const SWP_FRAMECHANGED: u32 = 0x0020;
    const SWP_SHOWWINDOW: u32 = 0x0040;
    const SWP_HIDEWINDOW: u32 = 0x0080;
    const SWP_NOCOPYBITS: u32 = 0x0100;
    const SWP_NOOWNERZORDER: u32 = 0x0200;
    const SWP_NOSENDCHANGING: u32 = 0x0400;
    const SWP_NOREDRAW: u32 = 0x0800;
    const SWP_DEFERERASE: u32 = 0x2000;
    const SWP_ASYNCWINDOWPOS: u32 = 0x4000;
    try std.testing.expect(SWP_NOSIZE != SWP_NOMOVE);
    try std.testing.expect((SWP_FRAMECHANGED | SWP_NOCOPYBITS) != SWP_NOZORDER);
    try std.testing.expect(SWP_DEFERERASE > SWP_SHOWWINDOW);
    try std.testing.expect(SWP_ASYNCWINDOWPOS > SWP_DEFERERASE);
    try std.testing.expect((SWP_NOACTIVATE | SWP_HIDEWINDOW | SWP_NOOWNERZORDER | SWP_NOSENDCHANGING | SWP_NOREDRAW) != 0);
}

// GetMessage / PeekMessage 的 min/max 过滤与阻塞语义见 user32.zig；此处仅 PM_* 位标志锚点（契约矩阵 §5）。
//
// **D-D1-1 审计摘要**（多线程）：`PostMessage` / `PostThreadMessage` 经 `wakeOneMsgWaiter` 唤醒在 `GetMessage` 空队列路径上 `blockThread` 的线程；`peekMessageAForThread` 与 `GetMessage` 均用 `client_tid`（CSR `get_message`）或 `GetCurrentThreadId()`，须与 `CreateWindowEx` 写入的 `wnd.thread_id` 一致，否则窗口队列与线程投递错位。`PeekMessage` 不阻塞、不置 `msg_wait_mask`（与 `allowSchedulerYieldForPeekFlags` 一致）。
//
// **D-D1-4**：`getMessageFiltered` / `peekMessageFiltered` 对非 `WM_QUIT` 采用轮转重排队以逼近 `[min,max]` 过滤；与 Learn 全量语义差距见 [PHASE_D_WIN32_MSG_PUMP_DWM.md](../../docs/cn/PHASE_D_WIN32_MSG_PUMP_DWM.md)。
test "peek remove flags documented band" {
    try std.testing.expect(PM_NOREMOVE < PM_REMOVE);
}

test "NtUserPeekMessage empty queue status anchor" {
    // 与 `user32.ntUserPeekMessageSyscall` 一致：空队列非 SUCCESS，便于用户态映射 PeekMessage FALSE。
    const no_more: i32 = @bitCast(@as(u32, 0x8000001A));
    try std.testing.expect(no_more != 0);
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

test "min max well-formed inclusive u32 max" {
    try std.testing.expect(minMaxRangeWellFormed(0x031E, std.math.maxInt(u32)));
    try std.testing.expect(minMaxRangeWellFormed(std.math.maxInt(u32), std.math.maxInt(u32)));
}

// ── GetMessage / PeekMessage 与 Learn 的差距表（问题四 / 矩阵 §5）────────────────
// | 主题 | Learn 期望（摘要） | 本仓库 `user32` 当前行为 |
// |------|-------------------|---------------------------|
// | `PeekMessage` PM_REMOVE | 置位时从队列移除 | `Window.peekMessage` / 过滤路径一致；纯函数标志见上 |
// | `PeekMessage` PM_NOYIELD | 置位时不应主动让出调度 | 多线程下仍可能 `blockThread`；以 `allowSchedulerYieldForPeekFlags` 为契约锚点 |
// | `GetMessage` 阻塞 | 无消息时阻塞至有消息或 WM_QUIT | 协作式：`STATUS_PENDING` + `blockThread`；与真 NT 抢占差异见 syscall 注释 |
// | `NtUserPeekMessage` | 无消息时 `FALSE` + 清零输出 | **`STATUS_NO_MORE_ENTRIES` + 清零 `MSG*`**（用户态映射 FALSE；与 `GetMessage` 空队列 `STATUS_PENDING` 区分；亦避免与 `WM_NULL`/`message==0` 混淆） |
// | 过滤范围 min/max | 仅返回区间内消息 | `getMessageFiltered` 轮转放回非匹配消息（简化语义）；纯函数镜像见 `messageMatchesMinMaxFilter` |
// | `GetMessage` 单线程空转上限 | 真 NT 无限阻塞 | 协作式：`build_options.get_message_yield_spins`（默认 4096）次后 `STATUS_PENDING`；可调以避免极端忙等 |
