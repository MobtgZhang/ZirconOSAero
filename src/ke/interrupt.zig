//! Kernel Interrupt Dispatch
//! Routes exceptions and IRQs to appropriate handlers
//! Supports unified InterruptFrame for full register context

const builtin = @import("builtin");
const arch = @import("../arch.zig");
const klog = @import("../rtl/klog.zig");
const scheduler = @import("scheduler.zig");

pub const InterruptFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const EXCEPTION_NAMES: [32][]const u8 = .{
    "Divide Error",
    "Debug",
    "NMI",
    "Breakpoint",
    "Overflow",
    "BOUND Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack-Segment Fault",
    "General Protection",
    "Page Fault",
    "Reserved",
    "x87 FPU Error",
    "Alignment Check",
    "Machine Check",
    "SIMD Error",
    "Virtualization",
    "Control Protection",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
};

pub fn handle(frame: *InterruptFrame) void {
    const vector: u8 = @intCast(frame.vector & 0xFF);

    if (vector < 32) {
        handleException(frame, vector);
    } else if (vector >= 32 and vector < 48) {
        handleIrq(frame, vector - 32);
    } else if (vector == 128) {
        handleSyscall(frame);
    } else {
        klog.warn("Unknown interrupt vector %u", .{vector});
    }
}

fn handleException(frame: *InterruptFrame, vector: u8) void {
    const name = if (vector < EXCEPTION_NAMES.len) EXCEPTION_NAMES[vector] else "Unknown";
    _ = name;

    if (vector == 14) {
        var cr2: u64 = 0;
        asm volatile ("mov %%cr2, %[cr2]"
            : [cr2] "=r" (cr2)
        );
        klog.err("Page Fault at RIP=0x%x, addr=0x%x, err=0x%x", .{
            frame.rip, cr2, frame.error_code,
        });
        arch.halt();
    }

    klog.err("Exception %u error_code=0x%x RIP=0x%x", .{
        vector, frame.error_code, frame.rip,
    });

    if (vector == 8 or vector == 13) {
        arch.halt();
    }
}

fn handleIrq(frame: *InterruptFrame, irq: u8) void {
    _ = frame;
    switch (irq) {
        0 => {
            scheduler.tick();
            // PS/2 在部分 QEMU/实机组合下 IRQ1/12 与主循环 hlt 竞态会漏包；每 tick 轮询排空 8042。
            if (builtin.target.cpu.arch == .x86_64) {
                const hub = @import("../drivers/input/input_hub.zig");
                hub.pollAll();
            }
        },
        1 => {
            if (builtin.target.cpu.arch == .x86_64) {
                // 旧路径：keyboard.handleIrq 只读 1 字节；8042 常一次积压整包(3–4B)，丢字节即错位。
                // poll() 会排空缓冲并按 aux/半包/bit3 规则路由键鼠，与主循环一致。
                const hub = @import("../drivers/input/input_hub.zig");
                hub.pollAll();
            } else {
                arch.handleKeyboardIrq();
            }
        },
        12 => {
            if (builtin.target.cpu.arch == .x86_64) {
                const hub = @import("../drivers/input/input_hub.zig");
                hub.pollAll();
            } else {
                arch.handleMouseIrq();
            }
        },
        else => {},
    }
    arch.sendEoi(irq);
}

fn handleSyscall(frame: *InterruptFrame) void {
    if (@import("build_options").enable_idt) {
        const syscall = @import("../arch/x86_64/syscall.zig");
        syscall.dispatch(frame);
    }
}
