// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/riscv64/smp_boot_stub.zig
// Purpose: RISC-V64 SMP 多核启动框架。通过 SBI HSM 启动 AP，使用 AP 栈和状态表。
//
// This is an independent clean-room implementation.
// Reference: RISC-V SBI Specification v2.0 HSM; OpenSBI Firmware Writer's Guide.

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");
const cpu_topo = @import("cpu_topology.zig");
const fdt = @import("fdt.zig");
const hsm = @import("sbi_hsm.zig");
const percpu = @import("percpu.zig");

/// AP 栈大小（16KiB，与 LoongArch64 一致）
const AP_STACK_SIZE: usize = 16384;

/// AP trampoline 页大小（须 identity-mapped，落在低 2GiB）
const AP_TRAMPOLINE_SIZE: usize = 4096;

/// 最大 Hart 数（与 fdt.MAX_HARTS 对齐）
const MAX_APS: usize = 64;

/// AP 启动信息表（存储在 .bss）
var ap_stacks: [MAX_APS][AP_STACK_SIZE]u8 align(16384) = undefined;
var ap_started: [MAX_APS]bool = undefined;

/// AP trampoline 代码（须在低 2GiB identity-mapped 区域）
/// 由 BSP 在 `initApBootEnvironment` 中写入
var ap_trampoline_phys: u64 = 0;

/// 标记当前 hart 是否为 BSP
pub fn isBsp() bool {
    return current_hart_id() == 0;
}

/// 获取当前 hart ID（从 CSR mhartid 或 sscratch 读取）
pub fn currentHartId() u32 {
    return current_hart_id();
}

fn current_hart_id() u32 {
    if (builtin.os.tag != .freestanding) return 0;
    return asm volatile ("csrr %[r], mhartid"
        : [r] "=r" (-> u32),
    );
}

/// AP 入口桩（Zig 占位；由 `src/arch/riscv64/ap_entry.S` 提供实际汇编）
extern fn riscv_ap_entry() void;

/// AP 初始化函数（由 AP trampoline 调用）
/// a0: 逻辑 CPU 索引（由 BSP 在 sbi_hsm.hartStart 启动参数中传递）
export fn riscv_ap_init(cpu_index: u32) void {
    if (builtin.cpu.arch != .riscv64) return;
    if (builtin.os.tag != .freestanding) return;

    const hart = current_hart_id();
    klog.info("RISC-V SMP: AP%u (cpu_index=%u) initializing...", .{ hart, cpu_index });

    // AP 使用传入的逻辑 CPU 索引初始化 per-CPU 数据
    _ = percpu.initPerCpu(cpu_index);

    // TODO: 设置 trap vector
    // TODO: 进入 scheduler.apProcessorIdleLoop()

    klog.info("RISC-V SMP: AP%u (cpu_index=%u) initialized, entering idle loop", .{ hart, cpu_index });

    // AP 进入 idle 循环
    while (true) {
        asm volatile ("wfi");
    }
}

/// 获取 AP 栈顶地址
pub fn getApStackTop(hart_index: u32) u64 {
    if (hart_index >= MAX_APS) return 0;
    return @intFromPtr(&ap_stacks[hart_index]) + AP_STACK_SIZE;
}

/// 标记 AP 已启动
pub fn markApStarted(hart_index: u32) void {
    if (hart_index < MAX_APS) {
        ap_started[hart_index] = true;
    }
}

/// 初始化 AP 启动环境
pub fn initApBootEnvironment() void {
    if (builtin.cpu.arch != .riscv64) return;

    const cpu_count = cpu_topo.logicalCpuCount();
    if (cpu_count <= 1) return;

    klog.info("RISC-V SMP: initializing boot environment for %u APs", .{cpu_count - 1});

    for (0..MAX_APS) |i| {
        ap_started[i] = false;
    }

    // 初始化 BSP per-CPU 数据
    _ = percpu.initPerCpu(0);

    // 将 ap_entry 物理地址记录下来
    // 假设 AP trampoline 代码位于低 2GiB identity-mapped 区域
    // 实际应通过运行时虚拟到物理地址转换
    const entry_va = @intFromPtr(&riscv_ap_entry);
    ap_trampoline_phys = entry_va; // TODO: 应转换为物理地址（identity mapping 假设成立）

    klog.info("RISC-V SMP: AP entry phys=0x%x stacks allocated", .{ap_trampoline_phys});
}

/// 通过 SBI HSM 启动单个 AP
/// hartid: 目标 hart 的硬件 ID
/// hart_index: 逻辑 CPU 编号（在 hart_ids[] 中的索引）
fn startHart(hartid: u32, hart_index: u32) void {
    if (hartid >= MAX_APS) return;

    const entry_phys = ap_trampoline_phys;

    // 4KiB 对齐检查
    if (entry_phys & 0xFFF != 0) {
        klog.err("RISC-V SMP: AP entry not 4KiB-aligned (0x%x)", .{entry_phys});
        return;
    }

    klog.debug("RISC-V SMP: starting hart%u (cpu_index=%u) entry=0x%x", .{
        hartid, hart_index, entry_phys,
    });

    // 通过 priv 参数传递逻辑 CPU 编号，AP 在 riscv_ap_init(a0) 中接收
    const result = hsm.hartStart(hartid, entry_phys, @as(u64, hart_index));
    if (result != 0) {
        klog.warn("RISC-V SMP: hart%u start failed (SBI err=%d)", .{ hartid, result });
        return;
    }

    // 等待 hart 达到 started 状态
    if (hsm.waitForHartStarted(hartid, 1000)) {
        markApStarted(hart_index);
        klog.info("RISC-V SMP: hart%u started successfully", .{hartid});
    } else {
        klog.warn("RISC-V SMP: hart%u start timeout", .{hartid});
    }
}

/// 启动所有 AP（从 FDT/DTB 解析的 hart 列表）
pub fn wakeApplicationProcessorsStub() void {
    if (builtin.cpu.arch != .riscv64) return;
    if (builtin.os.tag != .freestanding) return;

    const cpu_count = cpu_topo.logicalCpuCount();
    if (cpu_count <= 1) return;

    initApBootEnvironment();

    const bsp_hart = current_hart_id();
    klog.info("RISC-V SMP: BSP hart=%u waking %u APs", .{
        bsp_hart, cpu_count - 1,
    });

    for (1..@min(cpu_count, fdt.MAX_HARTS)) |i| {
        const hartid = fdt.hart_ids[i];
        if (hartid == bsp_hart) continue;
        startHart(hartid, @as(u32, @intCast(i)));
    }

    klog.info("RISC-V SMP: all APs dispatched", .{});
}

pub fn initSmpTopology() void {
    @import("cpu_topology.zig").initTopology();
}
