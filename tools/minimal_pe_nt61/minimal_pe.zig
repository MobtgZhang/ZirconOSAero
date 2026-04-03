// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tools/minimal_pe_nt61/minimal_pe.zig
// Purpose: 仓库内 **最小 x64 PE** 烟测产物（仅 `ExitProcess`）；不嵌入微软闭源 DLL；供 `zig build minimal-pe-nt61` 与可选 QEMU 加载实验。
//
// This is an independent clean-room implementation.

const std = @import("std");

pub fn main() noreturn {
    std.os.windows.kernel32.ExitProcess(42);
}
