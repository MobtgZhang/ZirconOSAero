//! LoongArch64：CPU 异常入口经 `arch/loongarch64/traps.zig` 转入此处（ESTAT.EXC = 64 + INT_*）。

const arch = @import("../arch.zig");
const klog = @import("../rtl/klog.zig");
const scheduler = @import("scheduler.zig");

/// Linux `arch/loongarch/include/asm/loongarch.h` INT_* 编号
pub const INT_TI: u32 = 11;
pub const INT_HWI0: u32 = 2;
pub const INT_HWI7: u32 = 9;

/// CSR.ESTAT 低 32 位有效（Linux `csr_read32(ESTAT)`）；EXC@[21:16]，IS@[14:0]。
fn excFromEstatWord(ew: u32) u32 {
    return (ew >> 16) & 0x3f;
}

fn isFromEstatWord(ew: u32) u32 {
    return ew & 0x7fff;
}

/// QEMU virt / 部分固件：中断已置 `ESTAT.IS`，但 `ExcCode` 仍为 0（手册称 RSV）；Linux 打印时亦将 EC=0 标成「INT」。
/// 此时按 IS 中已置位的中断号合成 `exc = 64 + intnum`，否则误当保留异常会 `halt` 在刚进入桌面的首次中断上。
fn synthesizeExcIfInterruptOnly(ew: u32, exc: u32) u32 {
    if (exc != 0) return exc;
    const is = isFromEstatWord(ew);
    if (is == 0) return 0;
    if ((is & (@as(u32, 1) << INT_TI)) != 0) return 64 + INT_TI;
    var b: u32 = INT_HWI0;
    while (b <= INT_HWI7) : (b += 1) {
        if ((is & (@as(u32, 1) << @intCast(b))) != 0) return 64 + b;
    }
    return @as(u32, 64) + @as(u32, @intCast(@ctz(is)));
}

/// 与 `traps.loongarch_dispatch_trap` 共用：先分辨 syscall（EC=11）再进中断路径。
pub fn resolvedExcCode(estat_full: u64) u32 {
    const ew = @as(u32, @truncate(estat_full));
    var exc = excFromEstatWord(ew);
    exc = synthesizeExcIfInterruptOnly(ew, exc);
    return exc;
}

/// 仅 `exc >= 64`（硬件中断号 = exc - 64）；异常与 syscall 在 `traps.zig` 处理。
pub fn dispatchHardwareInterrupts(exc: u32, ew: u32) void {
    _ = ew;
    if (exc < 64) {
        klog.err("LoongArch: dispatchHardwareInterrupts with EC=%u (internal error)", .{exc});
        arch.halt();
    }
    const intnum = exc - 64;
    if (intnum == INT_TI) {
        asm volatile ("csrwr %[v], 0x44"
            :
            : [v] "r" (@as(u64, 1)),
        );
        scheduler.tick();
        // 真抢占须在保存完整 GPR 后调用 `loongarch_switch_context`（`thread_switch.zig`）；当前与 x86 一致为逻辑切换索引。
        klog.notifyTimerTick();
        const hub = @import("../drivers/input/input_hub.zig");
        hub.pollAll();
        return;
    }
    if (intnum >= INT_HWI0 and intnum <= INT_HWI7) {
        const hub = @import("../drivers/input/input_hub.zig");
        hub.pollAll();
        const liointc = @import("../hal/loongarch64/liointc.zig");
        liointc.ackPchPending();
        return;
    }
    klog.warn("LoongArch: unhandled interrupt intnum=%u", .{intnum});
}

/// TLB 无效 / 页修改异常（ExcCode 1–4）→ VM 子系统缺页处理。
/// 1=TLBL（读无效），2=TLBS（存无效），3=TLBI（取指无效），4=TLBM（页修改）。
pub fn handleTlbPageFault(exc: u32) void {
    const badv = asm volatile ("csrrd %[o], 0x7"
        : [o] "=r" (-> u64),
    );
    const is_write = (exc == 2 or exc == 4);

    const process = @import("../ps/process.zig");
    if (process.getCurrentProcess()) |proc| {
        if (proc.address_space) |asp| {
            const vm = @import("../mm/vm.zig");
            if (vm.handleUserDemandOrCowFault(asp, badv, is_write)) {
                return;
            }
            const pid = proc.pid;
            _ = process.terminateProcess(pid, 0xC0000005);
            klog.err("LoongArch: user page fault ACCESS_VIOLATION (addr=0x%x EC=%u) PID=%u — terminated", .{
                badv, exc, pid,
            });
            arch.halt();
        }
    }

    const bc = @import("bugcheck.zig");
    bc.keBugCheckEx(.page_fault_in_nonpaged_area, badv, 0, exc, 0);
}

/// 单元测试或极简桩：`exc` 须为 **≥64** 的合成中断码（如 `64 + INT_TI`）。
pub fn dispatchFromExcCode(exc: u32) void {
    if (exc < 64) {
        klog.err("LoongArch: dispatchFromExcCode EC=%u — use traps path for exceptions/syscall", .{exc});
        arch.halt();
    }
    dispatchHardwareInterrupts(exc, exc << 16);
}
