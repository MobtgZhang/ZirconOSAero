// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/lapic_smp.zig
// Purpose: Local xAPIC MMIO 访问与 **INIT IPI**（目标 shorthand「除自身外全部」），供 K2.4 AP 唤醒前置；须保证 LAPIC 窗口已 identity 映射。
//
// This is an independent clean-room implementation.
// Reference: Intel SDM Vol.3 Ch.10 — Local APIC, ICR delivery modes; ACPI MADT.
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K2.4

const std = @import("std");
const madt = @import("madt.zig");

const REG_ICR_LOW: u32 = 0x300;
const REG_ICR_HIGH: u32 = 0x310;

/// ICR.Low：Delivery Mode INIT (101)、Level=1、Trigger=1、Destination Shorthand = All Excluding Self (11)。
/// 数值与常见固件/OS 公开描述一致；若改位布局须对照 Intel SDM 图 10-12。
const ICR_LOW_INIT_ALL_EXCLUDING_SELF: u32 = 0x000c4500;

/// Startup IPI：Delivery Mode Start-up (110)、Level=1、Edge、Shorthand All Excluding Self。
/// Vector = 目标物理地址 >> 12（实模式 CS:IP = Vector<<12:0）。
const ICR_LOW_SIPI_ALL_EXCLUDING_SELF_BASE: u32 = 0x000c4600;

/// 实模式 AP 自旋页（与 Intel MP / ACPI MADT 启动序列常见用法一致）；须位于低 1MiB 且 BSP 已 identity 映射。
pub const ap_trampoline_page_phys: u32 = 0x8000;

/// `startup_ipi` 向量 = `ap_trampoline_page_phys >> 12`（0x8 → 物理 0x8000）。
pub const ap_startup_ipi_vector: u8 = @truncate(ap_trampoline_page_phys >> 12);

/// 实模式 `jmp short $-2`（`EB FE`）无限自旋；在接长模式跳板前防止 AP 跑飞。
const TRAMPOLINE_SPIN16: [2]u8 = .{ 0xEB, 0xFE };

fn lapicRead(off: u32) u32 {
    const base: usize = @intCast(madt.local_apic_mmio_phys);
    const p: *const volatile u32 = @ptrFromInt(base + @as(usize, @intCast(off)));
    return p.*;
}

fn lapicWrite(off: u32, val: u32) void {
    const base: usize = @intCast(madt.local_apic_mmio_phys);
    const p: *volatile u32 = @ptrFromInt(base + @as(usize, @intCast(off)));
    p.* = val;
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

/// 在 **物理** `ap_trampoline_page_phys` 写入 16 位实模式自旋指令。
///
/// **unsafe**：依赖 BSP 已对该物理页建立 identity 映射（`main.zig` 低半区 identity 覆盖该地址）。
pub fn installApRealModeSpinTrampoline() void {
    const p: [*]volatile u8 = @ptrFromInt(@as(usize, ap_trampoline_page_phys));
    p[0] = TRAMPOLINE_SPIN16[0];
    p[1] = TRAMPOLINE_SPIN16[1];
}

/// 广播 **Startup IPI**，`vector` = 目标页号（通常为 `ap_startup_ipi_vector`）。
pub fn broadcastStartupIpiExcludingSelf(vector: u8) void {
    waitIcrIdle();
    lapicWrite(REG_ICR_HIGH, 0);
    waitIcrIdle();
    lapicWrite(REG_ICR_LOW, ICR_LOW_SIPI_ALL_EXCLUDING_SELF_BASE | @as(u32, vector));
    waitIcrIdle();
}

/// INIT 之后建议等待再发 SIPI；再执行两次 SIPI（间隔 ~200µs 量级）。
pub fn broadcastSipiSequenceTwiceAfterInit() void {
    delaySpinApprox(16_000_000);
    installApRealModeSpinTrampoline();
    broadcastStartupIpiExcludingSelf(ap_startup_ipi_vector);
    delaySpinApprox(50_000);
    broadcastStartupIpiExcludingSelf(ap_startup_ipi_vector);
    delaySpinApprox(200_000);
}

/// 向 **除 BSP 自身外** 的全部本地 APIC 发送 INIT IPI（AP 进入等待 SIPI 状态；须后续跳板 + SIPI 才能执行长模式入口）。
pub fn broadcastInitIpiExcludingSelf() void {
    waitIcrIdle();
    lapicWrite(REG_ICR_HIGH, 0);
    waitIcrIdle();
    lapicWrite(REG_ICR_LOW, ICR_LOW_INIT_ALL_EXCLUDING_SELF);
    waitIcrIdle();
}

/// BSP 侧 **INIT + SIPI×2**（实模式自旋跳板）；与 `smp_boot.tryStartApplicationProcessors` 一致。
pub fn broadcastInitAndSipiSequenceExcludingSelf() void {
    broadcastInitIpiExcludingSelf();
    broadcastSipiSequenceTwiceAfterInit();
}
