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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/apc_dpc.zig
// Purpose: Asynchronous Procedure Call (APC) and Deferred Procedure Call (DPC)
//          implementation, compatible with NT 6.1 semantics.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/
//      asynchronous-procedure-calls, deferred-procedure-calls

const std = @import("std");
const klog = @import("../rtl/klog.zig");
const ps = @import("../ps/process.zig");
const irq = @import("irq.zig");

/// APC processor mode
pub const ApcMode = enum(u8) {
    KernelMode = 0,
    UserMode = 1,
};

/// APC environment constants (NT-compatible)
pub const MAX_KERNEL_APCS_PER_THREAD = 8;
pub const MAX_USER_APCS_PER_THREAD = 16;
pub const MAX_DPCS_PER_PROCESSOR = 32;

/// APC routine prototype (matches NT 6.1 signature)
pub const ApcRoutine = *const fn (
    param1: u64,
    param2: u64,
    param3: u64,
) void;

/// DPC routine prototype (matches NT 6.1 signature)
pub const DpcRoutine = *const fn (
    dpc: *DpcObject,
    deferred_context: u64,
    system_argument1: u64,
    system_argument2: u64,
) void;

/// APC Object (NT 6.1 compatible structure subset)
pub const ApcObject = struct {
    mode: ApcMode,
    routine: ApcRoutine,
    param1: u64 = 0,
    param2: u64 = 0,
    param3: u64 = 0,
    pending: bool = false,
    inserted: bool = false,
    thread_id: u32 = 0,
};

/// DPC Object (NT 6.1 compatible structure subset)
pub const DpcObject = struct {
    routine: DpcRoutine,
    deferred_context: u64 = 0,
    system_argument1: u64 = 0,
    system_argument2: u64 = 0,
    pending: bool = false,
    inserted: bool = false,
    importance: u8 = 0, // 0: low, 1: medium, 2: high
    processor: u8 = 0, // Target processor number
};

/// Per-thread APC queue
pub const ThreadApcQueue = struct {
    kernel_apcs: [MAX_KERNEL_APCS_PER_THREAD]ApcObject = .{.{
        .mode = .KernelMode,
        .routine = undefined,
    }} ** MAX_KERNEL_APCS_PER_THREAD,
    user_apcs: [MAX_USER_APCS_PER_THREAD]ApcObject = .{.{
        .mode = .UserMode,
        .routine = undefined,
    }} ** MAX_USER_APCS_PER_THREAD,
    kernel_count: usize = 0,
    user_count: usize = 0,
    apc_pending: bool = false,
    user_apc_pending: bool = false,
    kernel_apc_disabled: bool = false,
};

/// Per-processor DPC queue
pub const DpcQueue = struct {
    dpcs: [MAX_DPCS_PER_PROCESSOR]DpcObject = .{.{
        .routine = undefined,
    }} ** MAX_DPCS_PER_PROCESSOR,
    count: usize = 0,
    dpc_pending: bool = false,
    dpc_running: bool = false,
};

/// Global DPC queues (one per logical processor)
var dpc_queues: [ps.MAX_PROCESSORS]DpcQueue = [_]DpcQueue{.{}} ** ps.MAX_PROCESSORS;
var apc_initialized: bool = false;
var dpc_initialized: bool = false;

/// Initialize APC subsystem
pub fn KeInitializeApc(
    apc: *ApcObject,
    mode: ApcMode,
    routine: ApcRoutine,
) void {
    apc.* = .{
        .mode = mode,
        .routine = routine,
        .pending = false,
        .inserted = false,
    };
}

/// Insert APC into target thread's queue
pub fn KeInsertQueueApc(
    thread_id: u32,
    apc: *ApcObject,
    param1: u64,
    param2: u64,
    param3: u64,
) bool {
    if (!apc_initialized) return false;
    if (apc.inserted) return false;

    const thread = ps.getThreadById(thread_id) orelse return false;

    apc.param1 = param1;
    apc.param2 = param2;
    apc.param3 = param3;
    apc.thread_id = thread_id;
    apc.pending = true;
    apc.inserted = true;

    const apc_queue = &thread.apc_queue;

    var success = false;
    switch (apc.mode) {
        .KernelMode => {
            if (apc_queue.kernel_count < MAX_KERNEL_APCS_PER_THREAD) {
                apc_queue.kernel_apcs[apc_queue.kernel_count] = apc.*;
                apc_queue.kernel_count += 1;
                apc_queue.apc_pending = true;
                success = true;
            }
        },
        .UserMode => {
            if (apc_queue.user_count < MAX_USER_APCS_PER_THREAD) {
                apc_queue.user_apcs[apc_queue.user_count] = apc.*;
                apc_queue.user_count += 1;
                apc_queue.apc_pending = true;
                apc_queue.user_apc_pending = true;
                success = true;
            }
        },
    }

    if (success) {
        // Wake thread if it's waiting
        ps.wakeThreadIfWaiting(thread_id);
    } else {
        apc.inserted = false;
        apc.pending = false;
    }

    return success;
}

/// Deliver pending APCs (called at interrupt exit or before returning to user mode)
pub fn KeDeliverApcs() void {
    if (!apc_initialized) return;
    const current_thread = ps.getCurrentThread() orelse return;
    const apc_queue = &current_thread.apc_queue;

    if (!apc_queue.apc_pending) return;
    if (apc_queue.kernel_apc_disabled) return;

    // Disable interrupts during APC delivery
    const irq_state = irq.disable();
    defer irq.restore(irq_state);

    // Deliver kernel APCs first
    while (apc_queue.kernel_count > 0) {
        apc_queue.kernel_count -= 1;
        const apc = &apc_queue.kernel_apcs[apc_queue.kernel_count];
        if (apc.pending) {
            apc.pending = false;
            apc.inserted = false;
            apc.routine(apc.param1, apc.param2, apc.param3);
        }
    }

    // Deliver user APCs only when returning to user mode
    // Note: This is handled in architecture-specific interrupt exit code
    if (irq.isUserModeReturn()) {
        while (apc_queue.user_count > 0) {
            apc_queue.user_count -= 1;
            const apc = &apc_queue.user_apcs[apc_queue.user_count];
            if (apc.pending) {
                apc.pending = false;
                apc.inserted = false;
                apc.routine(apc.param1, apc.param2, apc.param3);
            }
        }
        apc_queue.user_apc_pending = false;
    }

    apc_queue.apc_pending = apc_queue.user_apc_pending or (apc_queue.kernel_count > 0);
}

/// Disable kernel APC delivery
pub fn KeEnterCriticalRegion() void {
    const current_thread = ps.getCurrentThread() orelse return;
    current_thread.apc_queue.kernel_apc_disabled = true;
}

/// Enable kernel APC delivery
pub fn KeLeaveCriticalRegion() void {
    const current_thread = ps.getCurrentThread() orelse return;
    current_thread.apc_queue.kernel_apc_disabled = false;
    // Deliver any pending APCs now
    KeDeliverApcs();
}

/// Initialize DPC subsystem
pub fn KeInitializeDpc(
    dpc: *DpcObject,
    routine: DpcRoutine,
    deferred_context: u64,
) void {
    dpc.* = .{
        .routine = routine,
        .deferred_context = deferred_context,
        .pending = false,
        .inserted = false,
        .importance = 1, // Medium importance by default
        .processor = 0, // Current processor by default
    };
}

/// Insert DPC into target processor's queue
pub fn KeInsertQueueDpc(
    dpc: *DpcObject,
    system_argument1: u64,
    system_argument2: u64,
) bool {
    if (!dpc_initialized) return false;
    if (dpc.inserted) return false;

    dpc.system_argument1 = system_argument1;
    dpc.system_argument2 = system_argument2;
    dpc.pending = true;
    dpc.inserted = true;

    const processor = dpc.processor;
    if (processor >= ps.MAX_PROCESSORS) {
        dpc.inserted = false;
        dpc.pending = false;
        return false;
    }

    const dpc_queue = &dpc_queues[processor];
    if (dpc_queue.count >= MAX_DPCS_PER_PROCESSOR) {
        dpc.inserted = false;
        dpc.pending = false;
        return false;
    }

    // Insert DPC according to importance (high importance first)
    var insert_pos = dpc_queue.count;
    if (dpc.importance > 0) {
        for (0..dpc_queue.count) |i| {
            if (dpc_queue.dpcs[i].importance < dpc.importance) {
                insert_pos = i;
                break;
            }
        }
    }

    // Shift elements to make space
    if (insert_pos < dpc_queue.count) {
        var i = dpc_queue.count;
        while (i > insert_pos) : (i -= 1) {
            dpc_queue.dpcs[i] = dpc_queue.dpcs[i - 1];
        }
    }

    dpc_queue.dpcs[insert_pos] = dpc.*;
    dpc_queue.count += 1;
    dpc_queue.dpc_pending = true;

    // Request DPC interrupt
    irq.requestDpcInterrupt(processor);

    return true;
}

/// Process pending DPCs (called from DPC interrupt handler)
pub fn KeProcessDpcQueue() void {
    const processor = ps.getCurrentProcessorId();
    const dpc_queue = &dpc_queues[processor];

    if (!dpc_queue.dpc_pending) return;
    if (dpc_queue.dpc_running) return;

    dpc_queue.dpc_running = true;

    // Disable interrupts during DPC processing
    const irq_state = irq.disable();
    defer irq.restore(irq_state);

    while (dpc_queue.count > 0) {
        dpc_queue.count -= 1;
        var dpc = &dpc_queue.dpcs[dpc_queue.count];
        if (dpc.pending) {
            dpc.pending = false;
            dpc.inserted = false;
            dpc.routine(dpc, dpc.deferred_context, dpc.system_argument1, dpc.system_argument2);
        }
    }

    dpc_queue.dpc_pending = false;
    dpc_queue.dpc_running = false;
}

/// Initialize APC/DPC subsystem
pub fn init() void {
    // Initialize DPC queues
    for (&dpc_queues) |*q| {
        q.* = .{};
    }

    apc_initialized = true;
    dpc_initialized = true;

    klog.info("APC/DPC subsystem: initialized", .{});
}

// Test variables for APC/DPC tests
var test_apc_executed: bool = false;
var test_dpc_executed: bool = false;

fn testApcRoutine(param1: u64, param2: u64, param3: u64) void {
    _ = param1;
    _ = param2;
    _ = param3;
    test_apc_executed = true;
}

fn testDpcRoutine(dpc: *DpcObject, ctx: u64, arg1: u64, arg2: u64) void {
    _ = dpc;
    _ = ctx;
    _ = arg1;
    _ = arg2;
    test_dpc_executed = true;
}

test "APC initialization and insertion" {
    init();

    var apc: ApcObject = undefined;
    test_apc_executed = false;

    KeInitializeApc(&apc, .KernelMode, testApcRoutine);

    // Simulate current thread
    const thread_id = ps.getCurrentThreadId();
    try std.testing.expect(KeInsertQueueApc(thread_id, &apc, 1, 2, 3) == true);

    // Deliver APCs
    KeDeliverApcs();
    try std.testing.expect(test_apc_executed == true);
}

test "DPC initialization and insertion" {
    init();

    var dpc: DpcObject = undefined;
    test_dpc_executed = false;

    KeInitializeDpc(&dpc, testDpcRoutine, 0x1234);
    try std.testing.expect(KeInsertQueueDpc(&dpc, 0x5678, 0x9ABC) == true);

    // Process DPC queue
    KeProcessDpcQueue();
    try std.testing.expect(test_dpc_executed == true);
}
