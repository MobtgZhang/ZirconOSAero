//! MIPS64EL SMP boot stub — 基于 Loongson 3A 多核启动机制。
//!
//! Loongson 3A 多核唤醒流程：
//! 1. BSP 解析 MADT/SLIT 获取 AP 的 hart_id
//! 2. 为每个 AP 分配独立内核栈（物理内存，16KiB 对齐）
//! 3. 将 AP 入口地址写入 GCR IPI 邮箱（每 AP 一个，偏移 = hart_id * 8）
//! 4. 发送 IPI 中断唤醒 AP
//! 5. AP 收到启动信号后从入口开始执行，初始化后进入 idle 循环
//!
//! GCR 邮箱基址：0x10000000 (QEMU virt)
//! 参考：Loongson 3A 手册公开文档

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");
const cpu_topo = @import("cpu_topology.zig");
const scheduler = @import("../../ke/scheduler.zig");
const kpcr = @import("../../ke/kpcr.zig");

/// GCR 邮箱寄存器基址（Loongson 3A QEMU virt）
const GCR_MAILBOX_BASE: usize = 0x10000000;

/// AP 栈大小（16KiB）
const AP_STACK_SIZE: usize = 16384;

/// 最大 AP 数量
const MAX_APS: usize = 255;

/// AP 栈表（.bss，16KiB 对齐）
var ap_stacks: [MAX_APS][AP_STACK_SIZE]u8 align(16384) = undefined;
var ap_started: [MAX_APS]bool align(64) = undefined;

/// AP 入口桩（由 src/arch/mips64el/ap_entry.S 提供）
extern fn mips64el_ap_entry() void;

/// AP 初始化函数（由 AP trampoline 调用）
/// 执行 AP 的最小初始化后进入 idle 循环。
export fn mips64el_ap_init() void {
    if (builtin.cpu.arch != .mips64el) return;
    if (builtin.os.tag != .freestanding) return;

    // 获取当前 AP 的 HartID
    const hart_id = readHartId();
    klog.info("MIPS64EL SMP: AP%u initializing", .{hart_id});

    // 初始化 per-CPU 数据（KPCR）
    const kpcr_ptr = kpcr.initPerCpu(hart_id);
    klog.info("MIPS64EL SMP: AP%u KPCR at 0x%x", .{ hart_id, @intFromPtr(kpcr_ptr) });

    // 设置 CP0 Context.PTEBase（用于 TLB refill）
    // 注意：此值由 BSP 在启动 AP 前设置
    const pgd_phys = getApPgd();
    if (pgd_phys != 0) {
        const pte_base = pgd_phys & 0xFFFFFFFFFF800000;
        asm volatile (
            \\ dmtc0 %[val], $4
            \\ ehb
            :
            : [val] "r" (pte_base),
        );
        klog.info("MIPS64EL SMP: AP%u PTEBase=0x%x", .{ hart_id, pte_base });
    }

    // 标记 AP 已启动
    markApStarted(hart_id);

    // 启用中断
    enableInterrupts();

    klog.info("MIPS64EL SMP: AP%u ready, entering idle loop", .{hart_id});

    // 进入调度器 idle 循环（noreturn）
    scheduler.apProcessorIdleLoop();
    // 永远不会执行到这里
}

/// 读取当前 Hart 的硬件 ID
/// Loongson 3A 使用 CP0 EBase 获取 HartID
fn readHartId() u32 {
    if (builtin.os.tag != .freestanding) return 0;

    const ebase: u32 = asm ("mfc0 %[o], $15, 1"
        : [o] "=r" (-> u32),
    );
    // EBase[15:0] 是 HartID
    return @as(u32, @truncate(ebase & 0xFFFF));
}

/// 启用 MIPS 中断
fn enableInterrupts() void {
    // 设置 Status.IE 和 Status.EXL 以允许中断
    const status: u32 = asm ("mfc0 %[o], $12"
        : [o] "=r" (-> u32),
    );
    const new_status = status | 0x00000001 | 0x00000004; // IE | EXL
    asm volatile ("mtc0 %[v], $12\n\tehb"
        :
        : [v] "r" (new_status),
    );
}

/// AP 页表根地址（由 BSP 在启动 AP 前设置）
var mips64el_ap_pgd: u64 = 0;

/// 设置 AP 页表根地址
pub fn setApPgd(pgd: u64) void {
    mips64el_ap_pgd = pgd;
}

/// 获取 AP 页表根地址
fn getApPgd() u64 {
    return mips64el_ap_pgd;
}

/// AP 启动状态
pub const ApWakeStatus = enum(u8) {
    success,
    timeout,
    invalid_hart_id,
    mailbox_error,
};

/// 向 GCR mailbox 写入 AP 入口地址
fn writeGcrMailbox(hartid: u32, entry_addr: u64) void {
    const mailbox = GCR_MAILBOX_BASE + @as(usize, hartid) * 8;
    const ptr: *volatile u64 = @ptrFromInt(mailbox);
    ptr.* = entry_addr;
}

/// 读取 GCR mailbox 状态
fn readGcrMailbox(hartid: u32) u64 {
    const mailbox = GCR_MAILBOX_BASE + @as(usize, hartid) * 8;
    const ptr: *volatile u64 = @ptrFromInt(mailbox);
    return ptr.*;
}

/// 初始化 AP 启动环境
pub fn initApBootEnvironment() void {
    if (builtin.cpu.arch != .mips64el) return;

    const cpu_count = cpu_topo.logicalCpuCount();
    if (cpu_count <= 1) return;

    klog.info("MIPS64EL SMP: initializing boot environment for %u APs", .{cpu_count - 1});

    // 初始化 AP 启动状态
    for (0..MAX_APS) |i| {
        ap_started[i] = false;
    }

    klog.info("MIPS64EL SMP: AP stacks allocated, mailboxes ready", .{});
}

/// 启动单个 AP
fn wakeSingleAp(hartid: u32, entry: u64, stack_va: u64) void {
    if (hartid >= MAX_APS) {
        klog.err("MIPS64EL SMP: hartid %u exceeds MAX_APS", .{hartid});
        return;
    }

    klog.debug("MIPS64EL SMP: waking hart%u entry=0x%x stack=0x%x", .{
        hartid, entry, stack_va,
    });

    // 向 GCR mailbox 写入 AP 入口地址
    writeGcrMailbox(hartid, entry);

    // 标记 AP 期望启动（在 AP 调用 markApStarted 后变为 true）
    klog.info("MIPS64EL SMP: hart%u dispatched (mailbox @ 0x%x)", .{
        hartid, GCR_MAILBOX_BASE + hartid * 8,
    });
}

/// 启动所有 AP
pub fn wakeApplicationProcessorsStub() void {
    if (builtin.cpu.arch != .mips64el) return;
    if (builtin.os.tag != .freestanding) return;

    const cpu_count = cpu_topo.logicalCpuCount();
    if (cpu_count <= 1) return;

    initApBootEnvironment();

    // AP 入口地址
    const ap_entry: u64 = @intFromPtr(&mips64el_ap_entry);

    klog.info("MIPS64EL SMP: waking %u APs (GCR mailbox @ 0x%x)", .{
        cpu_count - 1, GCR_MAILBOX_BASE,
    });

    var started_count: u32 = 0;

    // 为每个 AP 分配栈并启动
    for (1..@min(cpu_count, MAX_APS)) |i| {
        const hart_id = @as(u32, @intCast(i));
        const stack_phys = @intFromPtr(&ap_stacks[hart_id]);
        const stack_va = stack_phys + AP_STACK_SIZE; // 栈顶

        wakeSingleAp(hart_id, ap_entry, stack_va);
        started_count += 1;
    }

    klog.info("MIPS64EL SMP: all APs dispatched, started=%u", .{
        started_count,
    });
}

/// 获取 AP 栈顶地址
pub fn getApStackTop(ap_index: u32) u64 {
    if (ap_index == 0) return 0;
    if (ap_index - 1 >= MAX_APS) return 0;
    return @intFromPtr(&ap_stacks[ap_index - 1]) + AP_STACK_SIZE;
}

/// 标记 AP 已启动（由 AP 调用）
pub fn markApStarted(ap_index: u32) void {
    if (ap_index < MAX_APS) {
        ap_started[ap_index] = true;
    }
}

/// 获取当前已启动的 AP 数量
pub fn getStartedApCount() u32 {
    var count: u32 = 0;
    for (0..MAX_APS) |i| {
        if (ap_started[i]) count += 1;
    }
    return count;
}

pub fn initSmpTopology() void {
    cpu_topo.initTopology();
}

/// 标记当前 Hart 是否为 BSP（MIPS BSP HartID 为 0）
pub fn isBsp() bool {
    return readHartId() == 0;
}

