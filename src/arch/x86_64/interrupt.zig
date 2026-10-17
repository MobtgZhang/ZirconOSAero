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

//! x86_64：IDT 异常 / PIC IRQ / 系统调用帧处理（`syscall` 经 `isr_common_handler` 进入 `handleSyscall`）

const builtin = @import("builtin");
const arch = @import("../../arch.zig");
const klog = @import("../../rtl/klog.zig");
const scheduler = @import("../../ke/scheduler.zig");
const process = @import("../../ps/process.zig");
const dpc = @import("../../ke/dpc.zig");
const irql_mod = @import("../../ke/irql.zig");

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

    if (vector == @import("isr.zig").ipi_tlb_flush_vector) {
        if (builtin.target.cpu.arch == .x86_64) {
            @import("../../hal/x86_64/tlb_broadcast.zig").flushLocal();
            @import("../../hal/x86_64/lapic_smp.zig").sendLocalEoi();
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
                    if (@import("../../mm/vm.zig").handleUserDemandOrCowFault(asp, cr2, is_write)) {
                        return;
                    }
                    const pid = proc.pid;
                    {
                        const paging = @import("paging.zig");
                        var cr0_diag: u64 = 0;
                        var cr4_diag: u64 = 0;
                        var efer_diag: u64 = 0;
                        var cr3_diag: u64 = 0;
                        var cs_diag: u16 = 0;
                        var ss_diag: u16 = 0;
                        asm volatile ("mov %%cr0, %[cr0]"
                            : [cr0] "=r" (cr0_diag),
                        );
                        asm volatile ("mov %%cr4, %[cr4]"
                            : [cr4] "=r" (cr4_diag),
                        );
                        asm volatile ("mov %%cr3, %[cr3]"
                            : [cr3] "=r" (cr3_diag),
                        );
                        asm volatile ("mov $0xc0000080, %%ecx; rdmsr; shl $32, %%rdx; or %%rdx, %[efer]"
                            : [efer] "=r" (efer_diag),
                            :
                            : .{ .rcx = true, .rax = true, .rdx = true });
                        asm volatile ("movw %%cs, %[cs]; movw %%ss, %[ss]"
                            : [cs] "=r" (cs_diag),
                              [ss] "=r" (ss_diag),
                        );
                        klog.err("PF cpu CR0=0x%x CR3=0x%x target_cr3=0x%x CR4=0x%x EFER=0x%x CS=0x%x SS=0x%x", .{ cr0_diag, cr3_diag, asp.pml4_phys, cr4_diag, efer_diag, cs_diag, ss_diag });
                        const v = paging.VirtAddr{ .value = cr2 };
                        const pml4 = @as(*paging.PageTable, @ptrFromInt(asp.pml4_phys));
                        const pml4e = pml4.entries[v.pml4Index()];
                        if (pml4e.isPresent()) {
                            const pdpt = @as(*paging.PageTable, @ptrFromInt(pml4e.toFrame()));
                            const pdpte = pdpt.entries[v.pdptIndex()];
                            if (pdpte.isPresent()) {
                                const pd = @as(*paging.PageTable, @ptrFromInt(pdpte.toFrame()));
                                const pde = pd.entries[v.pdIndex()];
                                klog.err("PF walk CR2=0x%x RIP=0x%x PML4E=0x%x PDPT=0x%x PD=0x%x", .{
                                    cr2,
                                    frame.rip,
                                    @as(u64, @bitCast(pml4e)),
                                    @as(u64, @bitCast(pdpte)),
                                    @as(u64, @bitCast(pde)),
                                });
                                if (pde.isPresent() and !pde.large) {
                                    const pt = @as(*paging.PageTable, @ptrFromInt(pde.toFrame()));
                                    const pte = pt.entries[v.ptIndex()];
                                    klog.err("PF walk PTE=0x%x", .{@as(u64, @bitCast(pte))});
                                    if (pte.isPresent()) {
                                        const code_page = @as([*]const volatile u8, @ptrFromInt(pte.toFrame() | (cr2 & 0xFFF)));
                                        klog.err("PF code bytes=0x%x 0x%x 0x%x 0x%x 0x%x 0x%x 0x%x 0x%x", .{
                                            code_page[0], code_page[1], code_page[2], code_page[3],
                                            code_page[4], code_page[5], code_page[6], code_page[7],
                                        });
                                    }
                                }
                            }
                        }
                    }
                    _ = process.terminateProcess(pid, 0xC0000005);
                    klog.err("User page fault: ACCESS_VIOLATION (addr=0x%x RIP=0x%x rsp=0x%x code=0x%x) PID=%u — process terminated", .{
                        cr2, frame.rip, frame.rsp, frame.error_code, pid,
                    });
                    arch.halt();
                }
            }
        }
        klog.err("Kernel PF frame rsp=0x%x cs=0x%x ss=0x%x rflags=0x%x", .{
            frame.rsp, frame.cs, frame.ss, frame.rflags,
        });
        if (scheduler.getCurrentThread()) |th| {
            klog.err("Kernel PF thread tid=%u pid=%u state=%u rsp0_stack_top=0x%x ctx_rsp=0x%x", .{
                th.id,
                th.process_id,
                @as(u32, @backingInt(th.state)),
                th.stack_top,
                th.context_storage.x86.rsp,
            });
        }
        const bc = @import("../../ke/bugcheck.zig");
        bc.keBugCheckEx(.page_fault_in_nonpaged_area, cr2, frame.rip, frame.error_code, 0);
    }

    klog.err("Exception %u error_code=0x%x RIP=0x%x", .{
        vector, frame.error_code, frame.rip,
    });

    if (vector == 6 and (frame.cs & 3) != 0) {
        if (scheduler.getCurrentThread()) |thread| {
            _ = process.terminateProcess(thread.process_id, 0xC000001D);
            klog.err("User invalid opcode: RIP=0x%x PID=%u — process terminated", .{ frame.rip, thread.process_id });
            arch.halt();
        }
    }

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
                const madt = @import("../../hal/x86_64/madt.zig");
                const kpcr = @import("../../ke/kpcr.zig");
                if (madt.logical_cpu_count > 1 and kpcr.currentThreadIndex() < 0) {
                    klog.notifyTimerTick();
                } else {
                    scheduler.tick();
                    if (scheduler.getTicks() % 100 == 0) {
                        arch.serialWrite("T");
                    }
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
                const kbd = @import("../../drivers/input/kbd.zig");
                kbd.handleIrq();
            } else {
                arch.handleKeyboardIrq();
            }
        },
        12 => {
            if (builtin.target.cpu.arch == .x86_64) {
                dpc.requestInputFlushDeferred();
                const virtio_input_pci = @import("../../drivers/input/virtio_input_pci.zig");
                const mouse = @import("../../drivers/input/mouse.zig");
                if (!(virtio_input_pci.isActive() and !@import("build_options").ps2_mouse_with_virtio)) {
                    mouse.handleIrq();
                }
            } else {
                arch.handleMouseIrq();
            }
        },
        else => {},
    }
    if (builtin.target.cpu.arch == .x86_64) {
        const ltt = @import("../../hal/x86_64/lapic_timer_tick.zig");
        if (irq == 0 and ltt.irq0UsesLapicEoi()) {
            @import("../../hal/x86_64/lapic_smp.zig").sendLocalEoi();
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
        const smap = @import("../../hal/x86_64/smap_user_access.zig");
        smap.syscallEnterAllowUserMemory();
        defer smap.syscallExitRestoreSmap();
        const syscall = @import("syscall.zig");
        syscall.dispatch(frame);
    }
}

/// **int 0x2E**（WOW64 / 兼容 32 位 NT 调用约定）：EAX=服务号，EDX=指向 stdcall 实参区（u32 槽）的指针。
fn handleWow64LegacySyscall(frame: *InterruptFrame) void {
    if (!@import("build_options").enable_idt) return;
    const smap = @import("../../hal/x86_64/smap_user_access.zig");
    smap.syscallEnterAllowUserMemory();
    defer smap.syscallExitRestoreSmap();
    const wow = @import("wow64_syscall.zig");
    wow.dispatchInt2e(frame);
    @import("../../ke/apc.zig").deliverKernelApcsForCurrentThread();
    if (process.getCurrentProcess()) |proc| {
        if (proc.address_space) |asp| asp.activate();
    }
}
