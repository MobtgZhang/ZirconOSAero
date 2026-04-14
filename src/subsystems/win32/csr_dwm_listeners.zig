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
// Module: src/subsystems/win32/csr_dwm_listeners.zig
// Purpose: csrss-side registry of thread ids for DWM notification delivery (LPC `register_dwm_listener`).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/dwm/dwm-overview

const MAX_DWM_LISTENERS: usize = 8;
var dwm_listener_tids: [MAX_DWM_LISTENERS]u32 = [_]u32{0} ** MAX_DWM_LISTENERS;
var dwm_listener_count: usize = 0;

/// Register `tid` for `PostThreadMessage` delivery on DWM policy broadcasts (deduplicated, capped).
pub fn register(tid: u32) void {
    if (tid == 0) return;
    for (dwm_listener_tids[0..dwm_listener_count]) |t| {
        if (t == tid) return;
    }
    if (dwm_listener_count >= MAX_DWM_LISTENERS) return;
    dwm_listener_tids[dwm_listener_count] = tid;
    dwm_listener_count += 1;
}

/// Copy registered listener tids into `out`; returns number written (<= out.len).
pub fn copyTids(out: []u32) usize {
    const n = @min(out.len, dwm_listener_count);
    @memcpy(out[0..n], dwm_listener_tids[0..n]);
    return n;
}

pub fn listenerCount() usize {
    return dwm_listener_count;
}

/// Test / reset helper (host tests only).
pub fn resetForTest() void {
    dwm_listener_count = 0;
    @memset(&dwm_listener_tids, 0);
}
