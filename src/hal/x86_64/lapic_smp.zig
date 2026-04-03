// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/lapic_smp.zig
// Purpose: Local xAPIC MMIO 访问与 **INIT/SIPI**（广播或按 APIC ID 物理目标）；须保证 LAPIC 窗口已 identity 映射。
//
// This is an independent clean-room implementation.
// Reference: Intel SDM Vol.3 Ch.10 — Local APIC, ICR delivery modes; ACPI MADT.
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K2.4

const std = @import("std");
const klog = @import("../../rtl/klog.zig");
const madt = @import("madt.zig");

const REG_ICR_LOW: u32 = 0x300;
const REG_ICR_HIGH: u32 = 0x310;
/// Spurious Interrupt Vector Register：bit 8 **APIC Software Enable**（Intel SDM Vol.3 §10.4.7）。
const REG_SVR: u32 = 0x0F0;
/// End Of Interrupt（写入任意值清除 in-service；Intel SDM Vol.3 §10.8.5）。
const REG_EOI: u32 = 0x0B0;

/// ICR.Low：Delivery Mode INIT (101)、Level=1、Trigger=1、Destination Shorthand = All Excluding Self (11)。
const ICR_LOW_INIT_ALL_EXCLUDING_SELF: u32 = 0x000c4500;

/// Startup IPI：Delivery Mode Start-up (110)、Level=1、Edge、Shorthand All Excluding Self。
const ICR_LOW_SIPI_ALL_EXCLUDING_SELF_BASE: u32 = 0x000c4600;

/// INIT：物理目标域、无 shorthand（bits 18-19=0）。Vector 对 INIT 无意义；与 SDM ICR 布局一致。
const ICR_LOW_INIT_PHYSICAL_BASE: u32 = 0x00004500;
/// SIPI：物理目标、Startup 投递。
const ICR_LOW_SIPI_PHYSICAL_BASE: u32 = 0x00004600;

/// 实模式 AP 跳板页（与 Intel MP / ACPI MADT 启动序列常见用法一致）；须位于低 1MiB 且 BSP 已 identity 映射。
pub const ap_trampoline_page_phys: u32 = 0x8000;

/// `startup_ipi` 向量 = `ap_trampoline_page_phys >> 12`（0x8 → 物理 0x8000）。
pub const ap_startup_ipi_vector: u8 = @truncate(ap_trampoline_page_phys >> 12);

fn lapicRead(off: u32) u32 {
    const base: usize = @intCast(madt.local_apic_mmio_phys);
    const p: *const volatile u32 = @ptrFromInt(base + @as(usize, @intCast(off)));
    return p.*;
}

fn lapicWrite(off: u32, val: u32) void {
    const base: usize = @intCast(madt.local_apic_mmio_phys);
    const p: *volatile u32 = @ptrFromInt(base + @as(usize, @intCast(off)));
    p.* = val;
    std.atomic.spinLoopHint();
}

fn waitIcrIdle() void {
    var spin: u32 = 0;
    while (spin < 0x100000) : (spin += 1) {
        if ((lapicRead(REG_ICR_LOW) & (1 << 12)) == 0) return;
        std.atomic.spinLoopHint();
    }
}

/// 粗延迟（INIT→SIPI、SIPI 间隔）；无 PIT 标定，仅数量级满足 Intel 建议的 10ms / 200µs 级等待。
fn delaySpinApprox(iterations: u32) void {
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        std.atomic.spinLoopHint();
    }
}

/// 向 **除 BSP 自身外** 的全部本地 APIC 发送 INIT IPI（AP 进入等待 SIPI 状态；须后续跳板 + SIPI 才能执行长模式入口）。
pub fn broadcastInitIpiExcludingSelf() void {
    waitIcrIdle();
    lapicWrite(REG_ICR_HIGH, 0);
    waitIcrIdle();
    lapicWrite(REG_ICR_LOW, ICR_LOW_INIT_ALL_EXCLUDING_SELF);
    waitIcrIdle();
}

/// 对指定 **APIC ID** 发送 INIT（物理目标；实机多 AP 时优于仅靠广播的时序假设）。
pub fn sendInitIpiToApicId(apic_id: u8) void {
    waitIcrIdle();
    lapicWrite(REG_ICR_HIGH, @as(u32, apic_id) << 24);
    waitIcrIdle();
    lapicWrite(REG_ICR_LOW, ICR_LOW_INIT_PHYSICAL_BASE);
    waitIcrIdle();
}

/// 广播 **Startup IPI**，`vector` = 目标页号（通常为 `ap_startup_ipi_vector`）。
pub fn broadcastStartupIpiExcludingSelf(vector: u8) void {
    waitIcrIdle();
    lapicWrite(REG_ICR_HIGH, 0);
    waitIcrIdle();
    lapicWrite(REG_ICR_LOW, ICR_LOW_SIPI_ALL_EXCLUDING_SELF_BASE | @as(u32, vector));
    waitIcrIdle();
}

/// 对指定 **APIC ID** 发送一次 SIPI（物理目标）。
pub fn sendStartupIpiToApicId(apic_id: u8, vector: u8) void {
    waitIcrIdle();
    lapicWrite(REG_ICR_HIGH, @as(u32, apic_id) << 24);
    waitIcrIdle();
    lapicWrite(REG_ICR_LOW, ICR_LOW_SIPI_PHYSICAL_BASE | @as(u32, vector));
    waitIcrIdle();
}

/// INIT 之后由调用方已等待时：按各 AP **APIC ID** 发 **SIPI×2**（两次间隔 ~200µs 量级）。
pub fn delayThenSipiTwicePerApic(vector: u8) void {
    var i: u32 = 0;
    while (i < madt.apic_id_count) : (i += 1) {
        const aid = madt.apic_ids[i];
        if (aid == madt.bsp_apic_id) continue;
        sendStartupIpiToApicId(aid, vector);
        delaySpinApprox(50_000);
        sendStartupIpiToApicId(aid, vector);
        delaySpinApprox(200_000);
    }
}

/// 兼容旧名：广播 SIPI×2（QEMU 全核同向量；实机优先 `delayThenSipiTwicePerApic`）。
pub fn broadcastSipiSequenceTwiceAfterInit(vector: u8) void {
    delaySpinApprox(16_000_000);
    broadcastStartupIpiExcludingSelf(vector);
    delaySpinApprox(50_000);
    broadcastStartupIpiExcludingSelf(vector);
    delaySpinApprox(200_000);
}

/// BSP 侧 **INIT** + **SIPI**（跳板由调用方先行写入 `ap_trampoline_page_phys`）。
pub fn broadcastInitAndSipiSequenceExcludingSelf() void {
    broadcastInitIpiExcludingSelf();
    broadcastSipiSequenceTwiceAfterInit(ap_startup_ipi_vector);
}

/// 按 MADT 中各 Local APIC **APIC ID** 单独 **INIT**，等待后再按 ID 发 **SIPI×2**（实机兼容路径）。
pub fn initAndSipiPerApicId() void {
    var i: u32 = 0;
    while (i < madt.apic_id_count) : (i += 1) {
        const aid = madt.apic_ids[i];
        if (aid == madt.bsp_apic_id) continue;
        sendInitIpiToApicId(aid);
    }
    delaySpinApprox(16_000_000);
    delayThenSipiTwicePerApic(ap_startup_ipi_vector);
}

/// 置位 SVR 的 APIC Enable；PIT/IRQ0 仍可作 tick 源，后续可接 LVT Timer（见 `lapic_timer_tick.zig`）。
pub fn ensureLocalApicSoftwareEnabled() void {
    if (madt.local_apic_mmio_phys == 0) return;
    const svr = lapicRead(REG_SVR);
    lapicWrite(REG_SVR, svr | 0x100);
}

/// 本地 APIC **EOI**（用于 LAPIC LVT Timer 等不经 8259 的路径）。
pub fn sendLocalEoi() void {
    if (madt.local_apic_mmio_phys == 0) return;
    lapicWrite(REG_EOI, 0);
}

/// Fixed 投递、**除自身外全部**（TLB shootdown / 跨核 DPC 唤醒等子集；向量须已在 IDT 登记）。
pub fn broadcastFixedIpiExcludingSelf(vector: u8) void {
    waitIcrIdle();
    lapicWrite(REG_ICR_HIGH, 0);
    waitIcrIdle();
    const low: u32 = 0x000C_4000 | (@as(u32, vector) & 0xFF);
    lapicWrite(REG_ICR_LOW, low);
    waitIcrIdle();
}
