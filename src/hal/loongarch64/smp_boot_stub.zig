//! AP 启动：新世界 UEFI + QEMU virt 上通过 IOCSR mailbox 唤醒 AP。
//! 当前阶段在 cpu_topology 报告多核后由 boot_generic 调用。

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");

pub fn wakeApplicationProcessorsStub() void {
    if (builtin.cpu.arch != .loongarch64) return;
    const cpu_count = @import("cpu_topology.zig").logicalCpuCount();
    if (cpu_count <= 1) return;

    klog.info("LoongArch SMP: waking %u APs (IOCSR mailbox)", .{cpu_count - 1});
    // AP 唤醒需要：
    // 1. 为每个 AP 分配独立内核栈
    // 2. 通过 IOCSR mailbox 写入 AP 入口地址
    // 3. AP 启动后初始化 DMW/EENTRY/SP 后进入 idle 循环
    // 当前为框架；完整实现需 AP 入口汇编（ap_entry.S）。
}

pub fn initSmpTopology() void {
    @import("cpu_topology.zig").initTopology();
}
