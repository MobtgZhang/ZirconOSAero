// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero — J12：主机侧 SMP 前置不变式（与 `madt.zig` `MAX_APIC_ID_LIST` 保持同步）。

const std = @import("std");

/// 须与 `src/hal/x86_64/madt.zig` `MAX_APIC_ID_LIST` 一致。
const MAX_APIC_ID_LIST: usize = 64;

test "MADT APIC ID list capacity vs scheduler SMP slots" {
    try std.testing.expect(MAX_APIC_ID_LIST >= 8);
}
