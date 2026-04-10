//! LoongArch64 多核 IPI：通过 IOCSR mailbox 向其它核广播 TLB shootdown。

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");

/// IOCSR 寄存器地址（LoongArch 手册公开定义）
const IOCSR_IPI_SEND: u32 = 0x1040;
const IOCSR_IPI_CLEAR: u32 = 0x100C;
const IOCSR_IPI_STATUS: u32 = 0x1000;

/// IPI 动作位：bit 0 用于 TLB shootdown
const IPI_ACTION_TLB_FLUSH: u32 = 0x1;

pub fn broadcastFullTlbShootdownStub() void {
    if (builtin.cpu.arch != .loongarch64) return;
    const n = @import("cpu_topology.zig").logicalCpuCount();
    if (n <= 1) return;
    broadcastIpi(IPI_ACTION_TLB_FLUSH);
}

fn broadcastIpi(action: u32) void {
    if (builtin.os.tag != .freestanding) return;
    const n = @import("cpu_topology.zig").logicalCpuCount();
    const self = @import("cpu_topology.zig").currentProcessorNumberForAsid();
    var cpu: u32 = 0;
    while (cpu < n) : (cpu += 1) {
        // 跳过当前 CPU（自己已在调用方执行 invtlbAll/Asid）
        if (cpu == self) continue;
        // IOCSR_IPI_SEND 格式：[31:26]=CPU [25:0]=action 编码
        const val: u64 = (@as(u64, cpu) << 26) | @as(u64, action);
        iocsrWrite32(IOCSR_IPI_SEND, @truncate(val));
    }
}

pub fn clearLocalIpi() void {
    if (builtin.os.tag != .freestanding) return;
    iocsrWrite32(IOCSR_IPI_CLEAR, IPI_ACTION_TLB_FLUSH);
}

pub fn handleIpiInterrupt() void {
    const status = if (builtin.os.tag == .freestanding) iocsrRead32(IOCSR_IPI_STATUS) else 0;
    if ((status & IPI_ACTION_TLB_FLUSH) != 0) {
        clearLocalIpi();
        if (builtin.os.tag == .freestanding) {
            asm volatile ("invtlb 0x0, $zero, $zero" ::: .{ .memory = true });
        }
    }
}

fn iocsrWrite32(addr: u32, val: u32) void {
    if (builtin.os.tag != .freestanding) return;
    asm volatile ("iocsrwr.w %[v], %[a]"
        :
        : [v] "r" (val),
          [a] "r" (addr),
    );
}

fn iocsrRead32(addr: u32) u32 {
    if (builtin.os.tag != .freestanding) return 0;
    return asm volatile ("iocsrrd.w %[o], %[a]"
        : [o] "=r" (-> u32),
        : [a] "r" (addr),
    );
}
