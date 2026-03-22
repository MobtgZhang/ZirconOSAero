//! PLIC (Platform-Level Interrupt Controller) driver for RISC-V 64
//! QEMU virt machine: PLIC at 0x0C000000

const PLIC_BASE: usize = 0x0C00_0000;

const PRIORITY_BASE = 0x0000;
const ENABLE_BASE = 0x2000;
const THRESHOLD_BASE = 0x20_0000;
const CLAIM_BASE = 0x20_0004;

fn priorityReg(irq: u32) *volatile u32 {
    return @ptrFromInt(PLIC_BASE + PRIORITY_BASE + @as(usize, irq) * 4);
}

fn enableReg(context: u32, irq: u32) *volatile u32 {
    return @ptrFromInt(PLIC_BASE + ENABLE_BASE + @as(usize, context) * 0x80 + @as(usize, irq / 32) * 4);
}

fn thresholdReg(context: u32) *volatile u32 {
    return @ptrFromInt(PLIC_BASE + THRESHOLD_BASE + @as(usize, context) * 0x1000);
}

fn claimReg(context: u32) *volatile u32 {
    return @ptrFromInt(PLIC_BASE + CLAIM_BASE + @as(usize, context) * 0x1000);
}

const CONTEXT_S: u32 = 1;

pub fn init() void {
    thresholdReg(CONTEXT_S).* = 0;
}

pub fn enableIrq(irq: u32) void {
    priorityReg(irq).* = 1;
    const reg = enableReg(CONTEXT_S, irq);
    const bit: u5 = @intCast(irq % 32);
    reg.* |= @as(u32, 1) << bit;
}

pub fn disableIrq(irq: u32) void {
    const reg = enableReg(CONTEXT_S, irq);
    const bit: u5 = @intCast(irq % 32);
    reg.* &= ~(@as(u32, 1) << bit);
}

pub fn claim() u32 {
    return claimReg(CONTEXT_S).*;
}

pub fn complete(irq: u32) void {
    claimReg(CONTEXT_S).* = irq;
}
