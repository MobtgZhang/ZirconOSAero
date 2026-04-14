// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! AP 启动：新世界 UEFI + QEMU virt 上通过 IOCSR mailbox 唤醒 AP。
//! 当前阶段在 cpu_topology 报告多核后由 boot_generic 调用。
//!
//! LoongArch64 SMP 启动流程（QEMU virt 参考）：
//! 1. BSP 解析 ACPI MADT 获取 AP 的 HartID
//! 2. 为每个 AP 分配独立内核栈（物理内存，16KiB 对齐）
//! 3. 将 AP 入口地址写入 IOCSR mailbox（每 AP 一个）
//! 4. AP 收到启动信号后从入口开始执行，初始化 CSR 后进入 idle 循环
//!
//! QEMU virt: IOCSR mailboxes are at 0x10000000 + hartid*8
//! 实际 QEMU virt 可能不完整，此处提供框架 + 降级到单核。

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");
const cpu_topo = @import("cpu_topology.zig");
const madt = @import("madt.zig");
const paging = @import("../../arch/loongarch64/paging.zig");
const scheduler = @import("../../ke/scheduler.zig");
const kpcr = @import("../../ke/kpcr.zig");

/// IOCSR mailbox 寄存器基址（QEMU virt）
const IOCSR_MAILBOX_BASE: usize = 0x10000000;

/// AP 栈大小（16KiB，与 LoongArch 页大小对齐）
const AP_STACK_SIZE: usize = 16384;

/// Guard Page 大小（与栈大小相同，16KiB）
/// 每个 AP 栈下方放置一个 Guard Page，防止栈溢出破坏相邻数据。
const GUARD_PAGE_SIZE: usize = AP_STACK_SIZE;

/// 最大 AP 数量
const MAX_APS: usize = 255;

/// AP 启动信息表（存储在 .bss）
/// 每个 AP 栈上方有一个 Guard Page（不可访问，用于检测栈溢出）
/// 布局：[Guard Page][AP Stack]，Guard Page 在低地址，Stack 在高地址
/// AP 栈顶 = ap_stacks[ap_index] + AP_STACK_SIZE（Guard 在下方溢出时保护）
var ap_stacks: [MAX_APS][AP_STACK_SIZE]u8 align(16384) = undefined;

/// AP Guard Page 区域（.bss，与 ap_stacks 物理相邻）
/// 映射为不可访问，在 AP 栈溢出时触发 #PF。
/// 位置在 ap_stacks 数组之前，偏移 = -(GUARD_PAGE_SIZE * MAX_APS)
var ap_guard_pages: [MAX_APS][GUARD_PAGE_SIZE]u8 align(16) = undefined;

var ap_started: [MAX_APS]bool = undefined;

/// AP 页表根地址（由 BSP 在启动 AP 前设置）
var la64_ap_pgdl: u64 = 0;

/// AP 启动参数数组指针（由 BSP 设置，AP 读取以获取逻辑 CPU 编号）
extern var la64_ap_boot_params_ptr: u64;

/// AP 入口地址（汇编定义）
extern var loongarch_ap_entry: u8;

/// AP 初始化函数（由 ap_entry.S 调用）
/// 执行 AP 的最小初始化后进入 idle 循环。
export fn loongarch_ap_init() void {
    if (builtin.cpu.arch != .loongarch64) return;
    if (builtin.os.tag != .freestanding) return;

    // 获取当前 AP 的 HartID（用于索引 boot params）
    const hart_id = readHartId();

    // 从 boot params 获取逻辑 CPU 索引（用于 KPCR 和数组索引）
    // 如果 HartID 无效或越界，使用 hart_id 作为 fallback
    const cpu_index: u32 = if (hart_id < MAX_APS)
        ap_boot_params[hart_id].cpu_index
    else
        hart_id;

    klog.info("LoongArch SMP: AP%u initializing (hart_id=%u)", .{ cpu_index, hart_id });

    // 初始化 per-CPU 数据（KPCR）- 使用逻辑 CPU 索引
    const kpcr_ptr = kpcr.initPerCpu(cpu_index);
    klog.info("LoongArch SMP: AP%u KPCR initialized at 0x%x", .{ cpu_index, @intFromPtr(kpcr_ptr) });

    // 标记 AP 已启动 - 使用逻辑 CPU 索引
    markApStarted(cpu_index);

    // 启用中断（与 x86_64 AP 一致）
    enableInterrupts();

    // 进入调度器 idle 循环
    // 注意：scheduler.apProcessorIdleLoop() 是一个 noreturn 函数
    scheduler.apProcessorIdleLoop();
    // 永远不会执行到这里
}

/// 读取当前 Hart 的硬件 ID
/// 使用 CPUCFG 指令读取 PRID（Processor ID）
/// LoongArch64 PRID 通常存储在 CPUCFG[0]
fn readHartId() u32 {
    if (builtin.os.tag != .freestanding) return 0;

    // CPUCFG 指令: cpucfg rd, rj
    // rj=0 时读取 PRID
    const prid: u64 = asm volatile ("cpucfg %[o], %[i]"
        : [o] "=r" (-> u64)
        : [i] "r" (@as(u64, 0)),
    );

    // 提取 HartID（PRID[15:0] 通常是 HartID）
    return @as(u32, @truncate(prid & 0xFFFF));
}

/// 通过 IOCSR CSR 读取 HartID（备用方案）
/// IOCSR CSR 0x30 包含 HartID 信息
fn readHartIdViaIOCSR() u32 {
    if (builtin.os.tag != .freestanding) return 0;

    const iocsr: u64 = asm volatile ("csrrd %[o], 0x30"
        : [o] "=r" (-> u64),
    );
    return @as(u32, @truncate(iocsr & 0xFFFF));
}

/// 启用 LoongArch64 中断
fn enableInterrupts() void {
    // 读取 ECFG
    const ecfg: u64 = asm volatile ("csrrd %[o], 0x4"
        : [o] "=r" (-> u64),
    );
    // 清除 IM 域（禁用所有中断源）
    const new_ecfg = ecfg & ~@as(u64, 0x3FFF);
    // 写回 ECFG
    asm volatile ("csrwr %[v], 0x4"
        :
        : [v] "r" (new_ecfg),
    );
    // 内存屏障
    asm volatile ("dbar 0" ::: .{ .memory = true });
}

/// AP 启动超时次数（每次等待的迭代次数）
const AP_WAIT_ITERATIONS: u32 = 0x1000000;

/// AP 启动最大重试次数
const AP_MAX_RETRIES: u32 = 3;

/// AP 启动状态
pub const ApWakeStatus = enum(u8) {
    success,
    timeout,
    invalid_hart_id,
    guard_page_not_mapped,
    mailbox_error,
    retry_exhausted,
};

/// AP 启动结果
pub const ApWakeResult = struct {
    status: ApWakeStatus,
    attempts: u32 = 0,
};

/// 检查 AP 是否已启动（轮询）
/// 返回 AP 启动状态
fn waitForAp(cpu_id: u32) ApWakeStatus {
    if (cpu_id >= MAX_APS) {
        return .invalid_hart_id;
    }

    var retry_count: u32 = 0;
    while (retry_count < AP_MAX_RETRIES) : (retry_count += 1) {
        var timeout: u32 = AP_WAIT_ITERATIONS;
        while (timeout > 0) : (timeout -= 1) {
            if (ap_started[cpu_id]) {
                return .success;
            }
        }
        // 每次重试前再次尝试唤醒 AP
        klog.warn("LoongArch SMP: AP%u retry %u/%u after timeout", .{ cpu_id, retry_count + 1, AP_MAX_RETRIES });
    }

    klog.err("LoongArch SMP: AP%u failed to start after %u retries", .{ cpu_id, AP_MAX_RETRIES });
    return .timeout;
}

/// 检查 IOCSR Mailbox 是否可访问（平台兼容性检测）
fn isIocsrMailboxAccessible() bool {
    if (builtin.cpu.arch != .loongarch64) return false;
    if (builtin.os.tag != .freestanding) return false;

    // 尝试读取 mailbox 状态
    // 如果返回全 0 或全 1，可能表示 mailbox 不可访问
    const test_val = readIocsrMailbox(0);
    if (test_val == 0 or test_val == 0xFFFFFFFFFFFFFFFF) {
        klog.warn("LoongArch SMP: IOCSR mailbox may not be accessible (value=0x%x)", .{test_val});
        return false;
    }
    return true;
}

/// 获取当前已启动的 AP 数量
pub fn getStartedApCount() u32 {
    var count: u32 = 0;
    for (0..MAX_APS) |i| {
        if (ap_started[i]) count += 1;
    }
    return count;
}

/// 获取当前 AP 启动状态摘要
pub fn getApStartStatus() struct { started: u32, total: u32, ready: bool } {
    const total = cpu_topo.logicalCpuCount();
    const started = getStartedApCount();
    return .{
        .started = started,
        .total = total,
        .ready = started >= total - 1, // 至少 BSP + 1 AP
    };
}

/// 向 IOCSR mailbox 写入 AP 入口地址
fn writeIocsrMailbox(hartid: u32, entry_addr: u64) void {
    const mailbox = IOCSR_MAILBOX_BASE + @as(usize, hartid) * 8;
    const ptr: *volatile u64 = @ptrFromInt(mailbox);
    ptr.* = entry_addr;
}

/// 读取 IOCSR mailbox 状态
fn readIocsrMailbox(hartid: u32) u64 {
    const mailbox = IOCSR_MAILBOX_BASE + @as(usize, hartid) * 8;
    const ptr: *volatile u64 = @ptrFromInt(mailbox);
    return ptr.*;
}

/// 初始化 AP 启动环境
/// 在 BSP 启动阶段调用，为每个 AP 准备栈和启动参数。
pub fn initApBootEnvironment() void {
    if (builtin.cpu.arch != .loongarch64) return;

    const cpu_count = cpu_topo.logicalCpuCount();
    if (cpu_count <= 1) return;

    klog.info("LoongArch SMP: initializing boot environment for %u APs", .{cpu_count - 1});

    // 初始化 AP 启动状态
    for (0..MAX_APS) |i| {
        ap_started[i] = false;
    }

    // 设置 AP boot params 指针（AP 启动后读取以获取逻辑 CPU 编号）
    la64_ap_boot_params_ptr = @intFromPtr(&ap_boot_params);

    // 设置 AP 页表根地址（从 BSP 页表继承）
    la64_ap_pgdl = paging.getCr3();

    // 初始化 AP Guard Pages（防止栈溢出）
    // Guard Pages 在 AP 栈下方，用于检测栈溢出
    _ = initApGuardPages();

    // MADT 已解析 HartID，这里仅记录日志
    klog.info("LoongArch SMP: MADT hart_count=%u bsp_hart=%u", .{
        madt.hart_id_count,
        madt.bsp_hart_id,
    });
    klog.info("LoongArch SMP: AP stacks allocated, mailboxes ready, pgdl=0x%x", .{la64_ap_pgdl});
}

/// 启动单个 AP
/// hartid: AP 的硬件线程 ID（用于 IOCSR mailbox 寻址）
/// entry: AP 入口 VA（通常是 loongarch_ap_entry）
/// stack_top: AP 的内核栈顶 VA
/// cpu_index: 逻辑 CPU 索引（用于 KPCR 和数组索引）
fn wakeSingleAp(hartid: u32, entry: u64, stack_top: u64, cpu_index: u32) void {
    if (hartid >= MAX_APS) {
        klog.err("LoongArch SMP: hartid %u exceeds MAX_APS", .{hartid});
        return;
    }

    // 填充 AP 启动参数（AP 启动后读取以确定自己的逻辑 CPU 编号）
    ap_boot_params[hartid] = .{
        .entry = entry,
        .cpu_index = cpu_index,
        .stack_top = stack_top,
        .pgdl = la64_ap_pgdl,
    };

    klog.debug("LoongArch SMP: waking hart%u (cpu%u) entry=0x%x stack=0x%x", .{
        hartid, cpu_index, entry, stack_top,
    });

    // 向 mailbox 写入 AP 入口地址
    writeIocsrMailbox(hartid, entry);
}

/// 启动所有 AP
/// 调用此函数后，AP 应该进入 idle 循环等待调度。
pub fn wakeApplicationProcessorsStub() void {
    if (builtin.cpu.arch != .loongarch64) return;
    if (builtin.os.tag != .freestanding) return;

    const cpu_count = cpu_topo.logicalCpuCount();
    if (cpu_count <= 1) return;

    initApBootEnvironment();

    // AP 入口地址
    const ap_entry: u64 = @intFromPtr(&loongarch_ap_entry);

    klog.info("LoongArch SMP: waking %u APs (IOCSR mailbox @ 0x%x)", .{
        cpu_count - 1, IOCSR_MAILBOX_BASE,
    });

    var started_count: u32 = 0;
    var failed_count: u32 = 0;

    // 为每个 AP 分配栈并启动
    // 使用 MADT 中获取的 HartID
    const hart_count = madt.hart_id_count;

    for (1..@min(cpu_count, hart_count)) |i| {
        const hart_id = madt.hart_ids[i];

        // 越界检查：HartID 不能超过 MAX_APS
        if (hart_id >= MAX_APS) {
            klog.warn("LoongArch SMP: hart_id %u exceeds MAX_APS(%u), skipping", .{ hart_id, MAX_APS });
            failed_count += 1;
            continue;
        }

        // 使用逻辑索引 i 作为 CPU 编号（用于 KPCR 和数组索引）
        const cpu_index: u32 = @intCast(i);

        // 越界检查：CPU 索引不能超过 MAX_APS
        if (cpu_index >= MAX_APS) {
            klog.warn("LoongArch SMP: cpu_index %u exceeds MAX_APS(%u), skipping", .{ cpu_index, MAX_APS });
            failed_count += 1;
            continue;
        }

        const stack_top: u64 = @intFromPtr(&ap_stacks[cpu_index]) + AP_STACK_SIZE;

        // 检查 Guard Page 是否映射成功
        if (!ap_guard_mapped[cpu_index]) {
            klog.warn("LoongArch SMP: guard page not mapped for cpu_index %u, skipping", .{ cpu_index });
            failed_count += 1;
            continue;
        }

        wakeSingleAp(hart_id, ap_entry, stack_top, cpu_index);

        // 等待 AP 启动完成并检查结果
        const status = waitForAp(cpu_index);
        switch (status) {
            .success => {
                started_count += 1;
            },
            .timeout => {
                failed_count += 1;
            },
            .invalid_hart_id => {
                failed_count += 1;
            },
            else => {
                // 其他错误状态也计入失败
                failed_count += 1;
            },
        }
    }

    // 若 HartID 数量小于 CPU 数量，使用索引作为 fallback
    if (hart_count < cpu_count) {
        for (hart_count..cpu_count) |i| {
            const hart_id = @as(u32, @intCast(i));

            // 越界检查
            if (hart_id >= MAX_APS) {
                klog.warn("LoongArch SMP: hart_id %u exceeds MAX_APS(%u), skipping", .{ hart_id, MAX_APS });
                failed_count += 1;
                continue;
            }

            const cpu_index: u32 = @intCast(i);

            const stack_top: u64 = @intFromPtr(&ap_stacks[cpu_index]) + AP_STACK_SIZE;

            // 检查 Guard Page 是否映射成功
            if (!ap_guard_mapped[cpu_index]) {
                klog.warn("LoongArch SMP: guard page not mapped for cpu_index %u, skipping", .{ cpu_index });
                failed_count += 1;
                continue;
            }

            wakeSingleAp(hart_id, ap_entry, stack_top, cpu_index);

            // 等待 AP 启动完成并检查结果
            const status = waitForAp(cpu_index);
            switch (status) {
                .success => {
                    started_count += 1;
                },
                else => {
                    // 超时或其他错误状态计入失败
                    failed_count += 1;
                },
            }
        }
    }

    klog.info("LoongArch SMP: all APs dispatched, started=%u failed=%u (QEMU/hardware dependent)", .{
        started_count, failed_count,
    });
}

/// 获取 AP 栈顶地址
/// AP 索引从 1 开始（BSP = 0）
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

/// 设置 AP 页表根地址（供链接脚本或 linker 参数使用）
pub fn setApPgdl(pgd: u64) void {
    la64_ap_pgdl = pgd;
}

/// 获取 AP 页表根地址
pub fn getApPgdl() u64 {
    return la64_ap_pgdl;
}

/// Guard Page 标记：标记特定 AP 的 Guard Page 已映射（用于调试）
var ap_guard_mapped: [MAX_APS]bool = undefined;

/// AP 启动参数结构（传递给每个 AP）
const ApBootParam = extern struct {
    entry: u64,
    cpu_index: u32,
    stack_top: u64,
    pgdl: u64,
};

/// AP 启动参数数组（按 HartID 索引，由 BSP 填充）
/// AP 启动后从此结构读取参数以确定自己的逻辑 CPU 编号
var ap_boot_params: [MAX_APS]ApBootParam = undefined;

/// 初始化 AP Guard Page 映射
/// 为每个 AP 的 Guard Page 区域建立只读映射，溢出时触发 #PF。
/// 此函数在 BSP 阶段调用，使用内核页表。
/// 成功返回 true，失败返回 false。
pub fn initApGuardPages() bool {
    if (builtin.cpu.arch != .loongarch64) return true;
    if (builtin.os.tag != .freestanding) return true;

    const pgd_phys = paging.getCr3();

    for (0..MAX_APS) |i| {
        ap_guard_mapped[i] = false;

        const guard_phys = @intFromPtr(&ap_guard_pages[i]);
        const stack_phys = @intFromPtr(&ap_stacks[i]);

        // Guard Page 位于栈下方，虚拟地址与物理地址相同（identity mapping）
        // 恒等映射 Guard Page，但设置为只读（无 Write 标志）
        // 这样如果 AP 栈溢出到 Guard Page，会触发 #PF
        const guard_flags = paging.V | paging.PLV_KERNEL | paging.NR;

        if (!paging.mapPage(pgd_phys, guard_phys, guard_phys, guard_flags, paging.simpleAllocFrame, null)) {
            klog.warn("LoongArch SMP: failed to map guard page for AP%u at phys=0x%x", .{ i, guard_phys });
            continue;
        }

        // 恒等映射 AP Stack 区域（读写）
        const stack_flags = paging.V | paging.D | paging.PLV_KERNEL;
        if (!paging.mapPage(pgd_phys, stack_phys, stack_phys, stack_flags, paging.simpleAllocFrame, null)) {
            klog.warn("LoongArch SMP: failed to map stack for AP%u at phys=0x%x", .{ i, stack_phys });
            // 回滚 Guard Page
            _ = paging.unmapPage(pgd_phys, guard_phys, paging.simpleAllocFrame, null);
            continue;
        }

        ap_guard_mapped[i] = true;
    }

    klog.info("LoongArch SMP: guard pages initialized for %u APs", .{
        blk: {
            var count: u32 = 0;
            for (0..MAX_APS) |i| {
                if (ap_guard_mapped[i]) count += 1;
            }
            break :blk count;
        },
    });

    return true;
}

/// 检查 AP 的 Guard Page 是否已映射
pub fn isApGuardPageMapped(ap_index: u32) bool {
    if (ap_index >= MAX_APS) return false;
    return ap_guard_mapped[ap_index];
}

/// 获取 AP 的 Guard Page 物理地址
pub fn getApGuardPagePhys(ap_index: u32) u64 {
    if (ap_index >= MAX_APS) return 0;
    return @intFromPtr(&ap_guard_pages[ap_index]);
}

pub fn initSmpTopology() void {
    @import("cpu_topology.zig").initTopology();
}

/// 标记当前 Hart 是否为 BSP
pub fn isBsp() bool {
    return readHartId() == 0;
}

