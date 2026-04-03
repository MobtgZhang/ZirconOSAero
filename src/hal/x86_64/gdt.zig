//! x86_64 GDT (Global Descriptor Table) and TSS (Task State Segment)
//! Sets up kernel/user segments and task state for Ring 0/3 transitions
//!
//! SMP：为最多 `MAX_GDT_TSS_CPUS` 个逻辑处理器各挂一对 TSS 描述符；`ltr` 每核独立（Intel SDM — TSS / IST）。

const percpu_mod = @import("percpu.zig");

const GdtEntry = packed struct(u64) {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_mid: u8 = 0,
    access: u8 = 0,
    flags_limit_high: u8 = 0,
    base_high: u8 = 0,
};

pub const Tss = extern struct {
    reserved0: u32 align(1) = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    ist1: u64 align(1) = 0,
    ist2: u64 align(1) = 0,
    ist3: u64 align(1) = 0,
    ist4: u64 align(1) = 0,
    ist5: u64 align(1) = 0,
    ist6: u64 align(1) = 0,
    ist7: u64 align(1) = 0,
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    iopb_offset: u16 align(1) = 104,
};

pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
/// Ring-3 **data / SS**（GDT 项 3）。须比 `USER_CS` 小 8，以满足 `SYSRET` 的 `SS=STAR_hi+8`、`CS=STAR_hi+16` 布局（Intel SDM）。
pub const USER_SS: u16 = 0x1B;
/// Ring-3 **code**（GDT 项 4）。须等于 `USER_SS + 8`。
pub const USER_CS: u16 = 0x23;
/// 用户数据段选择子（与 SS 相同档位的 ring-3 数据）。
pub const USER_DS: u16 = USER_SS;
/// 写入 `IA32_STAR` 高 16 位：`USER_SS == sysret_base + 8`、`USER_CS == sysret_base + 16`。
pub const IA32_STAR_SYSRET_BASE: u16 = USER_SS -% 8;
/// CPU0 的 TSS 选择子；CPU `i` 为 `TSS_SEL + @as(u16, i * 0x10)`。
pub const TSS_SEL: u16 = 0x28;

/// 与 `scheduler` `MAX_SCHED_CPUS` 对齐：GDT 中 TSS 槽数量。
pub const MAX_GDT_TSS_CPUS: usize = 8;

const segment_entries: usize = 5;
const tss_pair_entries: usize = 2 * MAX_GDT_TSS_CPUS;
const GDT_ENTRIES: usize = segment_entries + tss_pair_entries;

var gdt: [GDT_ENTRIES]GdtEntry align(16) = undefined;
var tss_by_cpu: [MAX_GDT_TSS_CPUS]Tss align(16) = undefined;

/// `syscall`/`sysret` 入口切换内核栈时读取（见 `syscall_lstar.s`）；与 BSP `tss_by_cpu[0].rsp0` 同步更新。
pub export var zircon_x86_64_kernel_rsp0: u64 = 0;

const GdtDescriptor = packed struct {
    limit: u16,
    base: u64,
};

fn makeEntry(base: u32, limit: u20, access: u8, flags: u4) GdtEntry {
    return .{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_mid = @truncate(base >> 16),
        .access = access,
        .flags_limit_high = (@as(u8, flags) << 4) | @as(u8, @truncate(limit >> 16)),
        .base_high = @truncate(base >> 24),
    };
}

fn writeTssPair(slot: usize, tss_ptr: *const Tss) void {
    const tss_base = @intFromPtr(tss_ptr);
    const tss_limit: u20 = @intCast(@sizeOf(Tss) - 1);
    gdt[slot] = .{
        .limit_low = @truncate(tss_limit),
        .base_low = @truncate(tss_base),
        .base_mid = @truncate(tss_base >> 16),
        .access = 0x89,
        .flags_limit_high = @as(u8, @truncate(tss_limit >> 16)),
        .base_high = @truncate(tss_base >> 24),
    };
    gdt[slot + 1] = @bitCast(@as(u64, @truncate(tss_base >> 32)));
}

pub fn init(kernel_stack: u64) void {
    gdt[0] = .{};
    gdt[1] = makeEntry(0, 0xFFFFF, 0x9A, 0xA);
    gdt[2] = makeEntry(0, 0xFFFFF, 0x92, 0xC);
    gdt[3] = makeEntry(0, 0xFFFFF, 0xF2, 0xC);
    gdt[4] = makeEntry(0, 0xFFFFF, 0xFA, 0xA);

    for (&tss_by_cpu) |*t| {
        t.* = .{};
        t.iopb_offset = @intCast(@sizeOf(Tss));
    }
    setupTss(kernel_stack);

    var i: usize = 0;
    while (i < MAX_GDT_TSS_CPUS) : (i += 1) {
        writeTssPair(segment_entries + i * 2, &tss_by_cpu[i]);
    }

    loadGdt();
    loadTssReg(TSS_SEL);
}

fn setupTss(kernel_stack: u64) void {
    tss_by_cpu[0].rsp0 = kernel_stack;
    zircon_x86_64_kernel_rsp0 = kernel_stack;
    percpu_mod.syncKernelRsp0(kernel_stack);
}

pub fn setKernelStack(stack: u64) void {
    tss_by_cpu[0].rsp0 = stack;
    zircon_x86_64_kernel_rsp0 = stack;
    percpu_mod.syncKernelRsp0(stack);
}

/// AP 在 SIPI 前设置 `tss_by_cpu[cpu_index].rsp0`（须 `cpu_index < MAX_GDT_TSS_CPUS`）。
pub fn setApKernelRsp0(cpu_index: u32, stack: u64) void {
    const i: usize = @intCast(cpu_index);
    if (i >= MAX_GDT_TSS_CPUS) return;
    tss_by_cpu[i].rsp0 = stack;
}

pub fn tssSelectorForCpu(cpu_index: u32) u16 {
    return TSS_SEL + @as(u16, @intCast(cpu_index * 0x10));
}

extern fn load_gdt_flush(desc: *const GdtDescriptor) void;
extern fn load_tss_reg(selector: u16) void;

fn loadGdt() void {
    const desc = GdtDescriptor{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };
    load_gdt_flush(&desc);
}

/// AP 长模式入口：与 BSP 共用同一张 GDT/描述符表（仅 `ltr` 不同）。
pub fn reloadKernelGdt() void {
    loadGdt();
}

fn loadTssReg(selector: u16) void {
    load_tss_reg(selector);
}

/// 加载本逻辑 CPU 对应的 TSS（`cpu_index` 0..`MAX_GDT_TSS_CPUS`-1）。
pub fn loadTaskRegisterForCpu(cpu_index: u32) void {
    loadTssReg(tssSelectorForCpu(cpu_index));
}
