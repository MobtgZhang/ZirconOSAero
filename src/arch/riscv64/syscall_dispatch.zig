//! RISC-V 64 ecall syscall dispatch.
//! Called from traps.zig when scause == 8 (U-mode ecall).
//! Convention: a7 = syscall number, a0–a5 = arguments, return in a0.
//! Reuses the x86_64 SSDT index table and shared service implementations.

const ssdt = @import("../x86_64/ssdt_nt61.zig");
const ntdll = @import("../../libs/ntdll.zig");
const klog = @import("../../rtl/klog.zig");
const TrapFrame = @import("traps.zig").TrapFrame;

fn ntResult(s: ntdll.NTSTATUS) i64 {
    return @as(i64, @bitCast(@as(u64, @intCast(@as(u32, @bitCast(s))))));
}

pub fn dispatch(frame: *TrapFrame) void {
    const num = frame.x17_a7;
    const a0 = frame.x10_a0;
    const a1 = frame.x11_a1;
    const a2 = frame.x12_a2;
    const a3 = frame.x13_a3;
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;

    const result: i64 = switch (num) {
        ssdt.NtYieldExecution => blk: {
            @import("../../ke/scheduler.zig").yield();
            break :blk 0;
        },
        ssdt.NtTerminateProcess => blk: {
            const process = @import("../../ps/process.zig");
            if (process.getCurrentProcess()) |proc| {
                _ = process.terminateProcess(proc.pid, 0);
            }
            break :blk 0;
        },
        else => blk: {
            klog.debug("riscv64: unhandled ecall num=0x%x", .{num});
            break :blk ntResult(ntdll.STATUS_NOT_IMPLEMENTED);
        },
    };

    frame.x10_a0 = @bitCast(result);
}
