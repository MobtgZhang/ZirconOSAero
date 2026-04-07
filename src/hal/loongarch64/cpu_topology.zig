//! LoongArch64 逻辑 CPU 数：通过 CPUCFG 探测或 ACPI MADT 解析。
//! 与 `ke/scheduler.zig` `schedNumCpus`、`ke/percpu_sched.zig` 对齐。

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");

var detected_cpu_count: u32 = 0;

pub fn logicalCpuCount() u32 {
    if (builtin.cpu.arch != .loongarch64) return 1;
    if (detected_cpu_count > 0) return detected_cpu_count;
    return 1;
}

pub fn initTopology() void {
    if (builtin.cpu.arch != .loongarch64) return;
    if (builtin.os.tag != .freestanding) {
        detected_cpu_count = 1;
        return;
    }

    const cpucfg0 = cpucfgRead(0);
    const prid = cpucfg0 & 0xFFFF;
    klog.info("LoongArch SMP: PRID=0x%x", .{@as(u32, @truncate(prid))});

    // QEMU virt 上 CPUCFG 不直接暴露核数；真实硬件需解析 ACPI MADT。
    // 当前阶段设为 1 核，后续接入 MADT 后动态更新。
    detected_cpu_count = 1;
}

fn cpucfgRead(idx: u32) u64 {
    if (builtin.os.tag != .freestanding) return 0;
    return asm volatile ("cpucfg %[o], %[i]"
        : [o] "=r" (-> u64),
        : [i] "r" (@as(u64, idx)),
    );
}
