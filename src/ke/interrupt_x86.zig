//! x86_64：IDT 异常 / PIC IRQ / 系统调用帧处理（`syscall` 经 `isr_common_handler` 进入 `handleSyscall`）

const builtin = @import("builtin");
const arch = @import("../arch.zig");
const klog = @import("../rtl/klog.zig");
const scheduler = @import("scheduler.zig");
const process = @import("../ps/process.zig");
const dpc = @import("dpc.zig");
const irql_mod = @import("irql.zig");

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

    if (vector == @import("../arch/x86_64/isr.zig").ipi_tlb_flush_vector) {
        if (builtin.target.cpu.arch == .x86_64) {
            @import("../hal/x86_64/tlb_broadcast.zig").flushLocal();
            @import("../hal/x86_64/lapic_smp.zig").sendLocalEoi();
        }
        return;
    }

    if (vector < 32) {
        handleException(frame, vector);
    } else if (vector == 0x2e) {
        handleWow64LegacySyscall(frame);
    } else if (vector >= 0x30 and vector < 0x40) {
        // 8259 重映射：IRQn → 向量 0x30+n（主片 0–7，从片 8–15）。
        handleIrq(frame, vector - 0x30);
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
        // #PF error code（Intel SDM Vol.3）：bit0=P present；bit1=W write；bit2=U user；bit3=RSVD；
        // bit4=I fetch；bit5=PK protection key（若启用）。用户态缺页：`tryLazyCommitFault`（MEM_RESERVE /
        // 节区视图惰性提交）→ `tryCowWriteFault`（共享 PFN 写时复制）。内核态或未处理用户态缺页：结构化 STOP。
        var cr2: u64 = 0;
        asm volatile ("mov %%cr2, %[cr2]"
            : [cr2] "=r" (cr2),
        );
        const user_fault = (frame.error_code & 4) != 0;
        if (user_fault) {
            if (process.getCurrentProcess()) |proc| {
                if (proc.address_space) |asp| {
                    const is_write = (frame.error_code & 2) != 0;
                    if (@import("../mm/vm.zig").handleUserDemandOrCowFault(asp, cr2, is_write)) {
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
        const bc = @import("bugcheck.zig");
        bc.keBugCheckEx(.page_fault_in_nonpaged_area, cr2, frame.rip, frame.error_code, 0);
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
    const entry_irql = irql_mod.getCurrentIrql();
    _ = irql_mod.raiseIrql(irql_mod.DEVICE_IRQL_LOW);
    defer irql_mod.lowerIrql(entry_irql);

    switch (irq) {
        0 => {
            // J10：AP 在 `apProcessorIdleLoop` 中 `currentThreadIndex()==-1` 时尚无每核 `current_thread`；
            // 仅 BSP（或已绑定调度线程的核）推进全局 `scheduler.tick`，避免 AP 误用 BSP 的 `current_thread`。
            if (builtin.target.cpu.arch == .x86_64) {
                const madt = @import("../hal/x86_64/madt.zig");
                const kpcr = @import("kpcr.zig");
                if (madt.logical_cpu_count > 1 and kpcr.currentThreadIndex() < 0) {
                    klog.notifyTimerTick();
                } else {
                    scheduler.tick();
                    klog.notifyTimerTick();
                }
            } else {
                scheduler.tick();
                klog.notifyTimerTick();
            }
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
    if (builtin.target.cpu.arch == .x86_64) {
        const ltt = @import("../hal/x86_64/lapic_timer_tick.zig");
        if (irq == 0 and ltt.irq0UsesLapicEoi()) {
            @import("../hal/x86_64/lapic_smp.zig").sendLocalEoi();
        } else {
            arch.sendEoi(irq);
        }
        irql_mod.lowerIrqlTo(irql_mod.DISPATCH_LEVEL);
        dpc.drainAtDispatchLevel();
    } else {
        arch.sendEoi(irq);
    }
}

fn handleSyscall(frame: *InterruptFrame) void {
    if (@import("build_options").enable_idt) {
        const smap = @import("../hal/x86_64/smap_user_access.zig");
        smap.syscallEnterAllowUserMemory();
        defer smap.syscallExitRestoreSmap();
        const syscall = @import("../arch/x86_64/syscall.zig");
        syscall.dispatch(frame);
    }
}

/// **int 0x2E**（WOW64 / 兼容 32 位 NT 调用约定）：EAX=服务号，EDX=指向 stdcall 实参区（u32 槽）的指针。
fn handleWow64LegacySyscall(frame: *InterruptFrame) void {
    if (!@import("build_options").enable_idt) return;
    const smap = @import("../hal/x86_64/smap_user_access.zig");
    smap.syscallEnterAllowUserMemory();
    defer smap.syscallExitRestoreSmap();
    const wow = @import("../arch/x86_64/wow64_syscall.zig");
    wow.dispatchInt2e(frame);
    @import("apc.zig").deliverKernelApcsForCurrentThread();
    if (process.getCurrentProcess()) |proc| {
        if (proc.address_space) |asp| asp.activate();
    }
}
