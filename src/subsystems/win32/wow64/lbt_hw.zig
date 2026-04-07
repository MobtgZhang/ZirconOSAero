//! LBT（Loongson Binary Translation Extension）硬件探测：
//! 通过 CPUCFG word 2 bit 11 检测是否支持 LBT（公开手册定义）。
//! LBT 提供硬件 x86 EFLAGS 寄存器、FP 栈顶指针等，可大幅降低二进制翻译成本。

const builtin = @import("builtin");
const klog = @import("../../../rtl/klog.zig");

var lbt_detected: enum { unknown, present, absent } = .unknown;

pub fn binaryTranslationExtensionsPresent() bool {
    if (builtin.cpu.arch != .loongarch64) return false;
    if (lbt_detected != .unknown) return lbt_detected == .present;
    lbt_detected = if (probeLbt()) .present else .absent;
    return lbt_detected == .present;
}

fn probeLbt() bool {
    if (builtin.os.tag != .freestanding) return false;
    // CPUCFG word 2 bit 11: LBT_X86（公开手册 Vol.1 §2.2）
    const cfg2 = cpucfgRead(2);
    const has_lbt_x86 = (cfg2 & (1 << 11)) != 0;
    if (has_lbt_x86) {
        klog.info("LBT: x86 binary translation extensions detected (CPUCFG[2] bit 11)", .{});
    }
    return has_lbt_x86;
}

fn cpucfgRead(idx: u32) u64 {
    if (builtin.os.tag != .freestanding) return 0;
    return asm volatile ("cpucfg %[o], %[i]"
        : [o] "=r" (-> u64),
        : [i] "r" (@as(u64, idx)),
    );
}
