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
