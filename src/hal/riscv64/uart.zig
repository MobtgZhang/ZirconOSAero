// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: hal/riscv64/uart.zig
// Purpose: QEMU `virt` 早期串口：NS16550 MMIO @0x10000000（与 -serial stdio 同源）；SBI legacy putchar 作回退。
//
// This is an independent clean-room implementation.
// Reference: QEMU hw/riscv/virt.c (UART0 MMIO base); NS16550 register map (public datasheets).

const max_mmio_spin: usize = 500_000;

/// QEMU RISC-V `virt`：UART0（ns16550），字节宽寄存器，与 EDK2/OpenSBI 常用调试口一致。
pub const UART_MMIO_BASE: usize = 0x1000_0000;

const rbr_thr: usize = 0;
const ier: usize = 1;
const fcr: usize = 2;
const lcr: usize = 3;
const lsr: usize = 5;

const lsr_thre: u8 = 1 << 5;
const lcr_dlab: u8 = 1 << 7;

fn reg8(off: usize) *volatile u8 {
    return @ptrFromInt(UART_MMIO_BASE + off);
}

fn sbiPutchar(ch: u8) void {
    asm volatile ("ecall"
        :
        : [ch] "{a0}" (@as(u64, ch)),
          [eid] "{a7}" (@as(u64, 0x01)),
    );
}

fn mmioTxByte(c: u8) bool {
    var n: usize = 0;
    while (n < max_mmio_spin) : (n += 1) {
        if (reg8(lsr).* & lsr_thre != 0) {
            reg8(rbr_thr).* = c;
            return true;
        }
    }
    return false;
}

/// 8N1 @115200：除数锁存 DLL=1（1.8432MHz 类时钟下常见）；固件已初始化时重复写入通常无害。
pub fn init() void {
    reg8(ier).* = 0;
    reg8(lcr).* = lcr_dlab;
    reg8(rbr_thr).* = 1;
    reg8(ier).* = 0;
    reg8(lcr).* = 0x03;
    reg8(fcr).* = 0x07;
}

pub fn write(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') {
            if (!mmioTxByte('\r')) sbiPutchar('\r');
        }
        if (!mmioTxByte(c)) sbiPutchar(c);
    }
}
