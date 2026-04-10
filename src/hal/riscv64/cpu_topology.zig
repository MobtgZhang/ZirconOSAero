//! RISC-V64 CPU 拓扑：通过 DTB 解析 + SBI HSM 获取逻辑 CPU 数。

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");

var detected_cpu_count: u32 = 1;

pub fn logicalCpuCount() u32 {
    if (builtin.cpu.arch != .riscv64) return 1;
    if (detected_cpu_count > 0) return detected_cpu_count;
    return 1;
}

pub fn setLogicalCpuCount(n: u32) void {
    detected_cpu_count = if (n == 0) 1 else n;
}

/// 读取当前 hart 的 hardware ID（CSR mhartid）
pub fn currentHartId() u32 {
    if (builtin.os.tag != .freestanding) return 0;
    return asm volatile ("csrr %[r], mhartid"
        : [r] "=r" (-> u32),
    );
}

/// 初始化 CPU 拓扑
/// dtb_phys: 从 boot.zig 传入的 DTB 物理地址（0 表示无 DTB）
pub fn initTopology(dtb_phys: usize) void {
    if (builtin.cpu.arch != .riscv64) return;

    const hart = currentHartId();
    klog.info("RISC-V SMP: current hart=%u", .{hart});

    const fdt = @import("fdt.zig");
    const hart_count = fdt.parse(dtb_phys);
    if (hart_count >= 1) {
        detected_cpu_count = hart_count;
        klog.info("RISC-V SMP: %u harts enumerated from DTB", .{hart_count});
    } else {
        detected_cpu_count = 1;
        klog.info("RISC-V SMP: using fallback 1 hart", .{});
    }
}
