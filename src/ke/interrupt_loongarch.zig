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

pub fn dispatchFromEstat(estat_full: u64) void {
    const ew = @as(u32, @truncate(estat_full));
    var exc = excFromEstatWord(ew);
    exc = synthesizeExcIfInterruptOnly(ew, exc);
    dispatchFromExcCodeResolved(exc, ew);
}

fn dispatchFromExcCodeResolved(exc: u32, ew: u32) void {
    if (exc < 64) {
        klog.err("LoongArch: exception EC=%u ESTAT.lo=0x%x (see ESTAT/BADV)", .{ exc, ew });
        arch.halt();
    }
    const intnum = exc - 64;
    if (intnum == INT_TI) {
        asm volatile ("csrwr %[v], 0x44"
            :
            : [v] "r" (@as(u64, 1)),
        );
        scheduler.tick();
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

/// 单元测试或极简桩可继续按「已解析的 ExcCode」调用（无 IS 修补）。
pub fn dispatchFromExcCode(exc: u32) void {
    dispatchFromExcCodeResolved(exc, exc << 16);
}
