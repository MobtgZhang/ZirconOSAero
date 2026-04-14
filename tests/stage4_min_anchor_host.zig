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
// ZirconOSAero — 阶段四最小锚点（SEH .pdata 视图、ALPC 占位、csrss 骨架可调用）。
//
// This is an independent clean-room implementation.

const std = @import("std");
const seh = @import("seh_pdata_min");
const alpc = @import("alpc_min");
const csrss = @import("csrss_skeleton");

test "IMAGE_RUNTIME_FUNCTION_ENTRY view is 12 bytes (x64 pdata row)" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(seh.RuntimeFunctionEntry));
}

test "ALPC port ref defaults to server kind" {
    const p = alpc.AlpcPortRef{};
    try std.testing.expect(p.kind == .server);
}

test "csrss skeleton init is no-op callable" {
    csrss.initCsrssSkeleton();
}
