// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/bugcheck.zig
// Purpose: 结构化内核停机（等价于公开文档中的 Bug Check 概念）；用于不可恢复异常路径（如内核 #PF）。
//
// This is an independent clean-room implementation.
// Ref: WDK — Bug Check Code Reference (public code list / names only).

const klog = @import("../rtl/klog.zig");
const arch = @import("../arch.zig");

/// 与 WDK 公开的 STOP 码名称对应的子集（数值为公开常量）。
pub const BugCheckCode = enum(u32) {
    unexpected_kernel_mode_trap = 0x0000007F,
    irql_not_less_or_equal = 0x0000000A,
    page_fault_in_nonpaged_area = 0x00000050,
    kmode_exception_not_handled = 0x0000001E,
    _,
};

/// 记录参数后永久停机（CLI + HLT 循环）；不返回。
pub fn keBugCheckEx(
    code: BugCheckCode,
    param1: usize,
    param2: usize,
    param3: usize,
    param4: usize,
) noreturn {
    if (@import("builtin").cpu.arch == .x86_64) {
        asm volatile ("cli" ::: .{ .memory = true });
    }
    klog.crit("*** STOP 0x{X:0>8} (0x{X:0>16} 0x{X:0>16} 0x{X:0>16} 0x{X:0>16})",
        .{ @intFromEnum(code), param1, param2, param3, param4 });
    while (true) {
        arch.halt();
    }
}

pub fn keBugCheck(code: BugCheckCode) noreturn {
    keBugCheckEx(code, 0, 0, 0, 0);
}
