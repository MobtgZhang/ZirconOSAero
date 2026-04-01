//! x86_64：IDT 异常 / PIC IRQ / int 0x80 系统调用分发（原 `interrupt.zig` 主体）

const builtin = @import("builtin");
const arch = @import("../arch.zig");
const klog = @import("../rtl/klog.zig");
const scheduler = @import("scheduler.zig");
const process = @import("../ps/process.zig");
const dpc = @import("dpc.zig");

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

const EXCEPTION_NAMES = [_][]const u8{
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
            : [cr2] "=r" (cr2),
        );
        const user_fault = (frame.error_code & 4) != 0;
        if (user_fault) {
            if (process.getCurrentProcess()) |proc| {
                if (proc.address_space) |_| {
                    var asp = proc.address_space.?;
                    if (@import("../mm/vm.zig").handleLazyCommitFault(&asp, cr2)) {
                        proc.address_space = asp;
                        return;
                    }
                    const pid = proc.pid;
                    _ = process.terminateProcess(pid, 0xC0000005);
                    klog.err("User page fault: ACCESS_VIOLATION (addr=0x%x) PID=%u — process terminated", .{
                        cr2, pid,
                    });
                    arch.halt();
                }
            }
        }
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
            if (builtin.target.cpu.arch == .x86_64) {
                dpc.requestInputFlushDeferred();
            }
        },
        1 => {
            if (builtin.target.cpu.arch == .x86_64) {
                dpc.requestInputFlushDeferred();
            } else {
                arch.handleKeyboardIrq();
            }
        },
        12 => {
            if (builtin.target.cpu.arch == .x86_64) {
                dpc.requestInputFlushDeferred();
            } else {
                arch.handleMouseIrq();
            }
        },
        else => {},
    }
    arch.sendEoi(irq);
    if (builtin.target.cpu.arch == .x86_64) {
        dpc.drainPending();
    }
}

fn handleSyscall(frame: *InterruptFrame) void {
    if (@import("build_options").enable_idt) {
        const syscall = @import("../arch/x86_64/syscall.zig");
        syscall.dispatch(frame);
    }
}
