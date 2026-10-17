// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - Unified HAL scheduler context
// The kernel scheduler stores one opaque context slot per thread.  This module
// owns the platform representation and keeps assembly/layout details out of the
// upper kernel.

const builtin = @import("builtin");

const LaContext = @import("../arch/loongarch64/thread_switch.zig").LaThreadContext;
const RvContext = @import("../arch/riscv64/thread_switch.zig").RvThreadContext;
const A64Context = @import("../arch/aarch64/thread_switch.zig").A64ThreadContext;
const MipsContext = @import("../arch/mips64el/thread_switch.zig").MipsThreadContext;
const X86Context = @import("../arch/x86_64/thread_switch.zig").X86ThreadContext;

pub const ContextStorage = extern union {
    la: LaContext,
    rv: RvContext,
    a64: A64Context,
    mips: MipsContext,
    x86: X86Context,
};

pub const ContextStorageAlignment = @alignOf(ContextStorage);

/// Initialize a newly created kernel thread and return its initial stack pointer.
pub fn initThreadContext(storage: *ContextStorage, entry: u64, stack_top: usize) usize {
    storage.* = undefined;

    switch (builtin.target.cpu.arch) {
        .loongarch64 => {
            const context: *LaContext = @ptrCast(storage);
            @import("../arch/loongarch64/thread_switch.zig").initNewThread(context, entry, stack_top);
            return context.sp;
        },
        .riscv64 => {
            const context: *RvContext = @ptrCast(storage);
            @import("../arch/riscv64/thread_switch.zig").initNewThread(context, entry, stack_top);
            return context.sp;
        },
        .aarch64 => {
            const context: *A64Context = @ptrCast(storage);
            @import("../arch/aarch64/thread_switch.zig").initNewThread(context, entry, stack_top);
            return context.sp;
        },
        .mips64el => {
            const context: *MipsContext = @ptrCast(storage);
            @import("../arch/mips64el/thread_switch.zig").initNewThread(context, entry, stack_top);
            return context.sp;
        },
        .x86_64 => {
            if (builtin.target.os.tag == .freestanding) {
                const context: *X86Context = @ptrCast(storage);
                @import("../arch/x86_64/thread_switch.zig").initNewThread(context, entry, stack_top);
            }
            return stack_top;
        },
        else => @compileError("initThreadContext: unsupported architecture"),
    }
}

/// Switch from `from` to `to`.  Returns false when the current build is a host
////test target without linked context-switch trampolines.  On freestanding
/// targets a successful switch does not return to the caller.
pub fn switchContext(from: *ContextStorage, to: *ContextStorage) bool {
    switch (builtin.target.cpu.arch) {
        .loongarch64 => {
            @import("../arch/loongarch64/thread_switch.zig").loongarch_switch_context(
                @ptrCast(from),
                @ptrCast(to),
            );
            return true;
        },
        .riscv64 => {
            @import("../arch/riscv64/thread_switch.zig").riscv_switch_context(
                @ptrCast(from),
                @ptrCast(to),
            );
            return true;
        },
        .aarch64 => {
            @import("../arch/aarch64/thread_switch.zig").aarch64_switch_context(
                @ptrCast(from),
                @ptrCast(to),
            );
            return true;
        },
        .mips64el => {
            @import("../arch/mips64el/thread_switch.zig").mips64_switch_context(
                @ptrCast(from),
                @ptrCast(to),
            );
            return true;
        },
        .x86_64 => {
            if (builtin.target.os.tag != .freestanding) return false;
            @import("../arch/x86_64/thread_switch.zig").x86_64_switch_context(
                @ptrCast(from),
                @ptrCast(to),
                next_address_space_cr3,
            );
            unreachable;
        },
        else => @compileError("switchContext: unsupported architecture"),
    }
}

/// CR3 to activate after the target stack has become current.  Only x86_64
/// freestanding context switches consume this value; zero keeps the current
/// address space.
pub var next_address_space_cr3: u64 = 0;
