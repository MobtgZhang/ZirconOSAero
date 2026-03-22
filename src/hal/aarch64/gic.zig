//! GICv2 (Generic Interrupt Controller) driver for AArch64
//! QEMU virt machine: GICD at 0x08000000, GICC at 0x08010000

const GICD_BASE: usize = 0x0800_0000;
const GICC_BASE: usize = 0x0801_0000;

fn gicdReg(offset: usize) *volatile u32 {
    return @ptrFromInt(GICD_BASE + offset);
}

fn giccReg(offset: usize) *volatile u32 {
    return @ptrFromInt(GICC_BASE + offset);
}

const GICD_CTLR = 0x000;
const GICD_ISENABLER = 0x100;
const GICD_ICENABLER = 0x180;
const GICD_IPRIORITYR = 0x400;
const GICD_ITARGETSR = 0x800;
const GICD_ICFGR = 0xC00;

const GICC_CTLR = 0x000;
const GICC_PMR = 0x004;
const GICC_IAR = 0x00C;
const GICC_EOIR = 0x010;

pub fn init() void {
    gicdReg(GICD_CTLR).* = 0;

    var i: usize = 32;
    while (i < 1020) : (i += 1) {
        const reg_idx = i / 4;
        const byte_off = (i % 4) * 8;
        const pri_reg = gicdReg(GICD_IPRIORITYR + reg_idx * 4);
        var val = pri_reg.*;
        val &= ~(@as(u32, 0xFF) << @as(u5, @intCast(byte_off)));
        val |= @as(u32, 0xA0) << @as(u5, @intCast(byte_off));
        pri_reg.* = val;
    }

    gicdReg(GICD_CTLR).* = 1;

    giccReg(GICC_PMR).* = 0xFF;
    giccReg(GICC_CTLR).* = 1;
}

pub fn enableIrq(irq: u32) void {
    const reg_idx = irq / 32;
    const bit: u5 = @intCast(irq % 32);
    gicdReg(GICD_ISENABLER + reg_idx * 4).* = @as(u32, 1) << bit;

    if (irq >= 32) {
        const target_reg = irq / 4;
        const target_off: u5 = @intCast((irq % 4) * 8);
        const tgt = gicdReg(GICD_ITARGETSR + target_reg * 4);
        tgt.* |= @as(u32, 0x01) << target_off;
    }
}

pub fn disableIrq(irq: u32) void {
    const reg_idx = irq / 32;
    const bit: u5 = @intCast(irq % 32);
    gicdReg(GICD_ICENABLER + reg_idx * 4).* = @as(u32, 1) << bit;
}

pub fn acknowledge() u32 {
    return giccReg(GICC_IAR).*;
}

pub fn endOfInterrupt(irq: u32) void {
    giccReg(GICC_EOIR).* = irq;
}
