// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - Unified HAL per-CPU runtime

const builtin = @import("builtin");
const std = @import("std");

pub const PerCpu = extern struct {
    kernel_rsp0: u64 align(8) = 0,
    processor_number: u32 align(8) = 0,
    current_thread_index: i32 = -1,
    _pad0: u32 = 0,
    kernel_sp: u64 = 0,
    self_pointer: u64 = 0,
    current_asid: u8 = 0,
    _pad2: [7]u8 = @splat(0),
};

var g_processor_number: u32 = 0;
var g_current_thread_index: i32 = -1;

var percpu_storage: [256]PerCpu align(64) = undefined;

fn readTlsPointer() u64 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            if (builtin.os.tag != .freestanding) return 0;
            return asm volatile ("movq %%gs:24, %[out]"
                : [out] "=r" (-> u64),
            );
        },
        .aarch64 => {
            return asm volatile ("mrs %[v], tpidr_el1"
                : [v] "=r" (-> u64),
            );
        },
        .loongarch64 => {
            if (builtin.os.tag != .freestanding) return 0;
            return asm volatile ("csrrd %[o], 0x30"
                : [o] "=r" (-> u64),
            );
        },
        else => return 0,
    }
}

pub fn setProcessorNumber(cpu: u32) void {
    const pointer = readTlsPointer();
    if (pointer != 0) {
        const percpu: *PerCpu = @ptrFromInt(pointer);
        percpu.processor_number = cpu;
        return;
    }
    g_processor_number = cpu;
}

pub fn currentProcessorNumber() u32 {
    const pointer = readTlsPointer();
    if (pointer != 0) {
        const percpu: *PerCpu = @ptrFromInt(pointer);
        return percpu.processor_number;
    }
    return g_processor_number;
}

pub fn setCurrentThreadIndex(index: i32) void {
    const pointer = readTlsPointer();
    if (pointer != 0) {
        const percpu: *PerCpu = @ptrFromInt(pointer);
        percpu.current_thread_index = index;
        return;
    }
    g_current_thread_index = index;
}

pub fn currentThreadIndex() i32 {
    const pointer = readTlsPointer();
    if (pointer != 0) {
        const percpu: *PerCpu = @ptrFromInt(pointer);
        return percpu.current_thread_index;
    }
    return g_current_thread_index;
}

pub fn initPerCpu(cpu_index: u32) *PerCpu {
    const percpu = &percpu_storage[cpu_index];
    percpu.* = .{
        .processor_number = cpu_index,
        .current_thread_index = -1,
        .kernel_sp = 0,
        .self_pointer = @intFromPtr(percpu),
    };

    switch (builtin.cpu.arch) {
        .aarch64 => {
            asm volatile ("msr tpidr_el1, %[v]"
                :
                : [v] "r" (@intFromPtr(percpu)),
            );
        },
        .loongarch64 => {
            if (builtin.os.tag == .freestanding) {
                asm volatile ("csrwr %[v], 0x30"
                    :
                    : [v] "r" (@intFromPtr(percpu)),
                );
            }
        },
        else => {},
    }

    return percpu;
}

pub fn setCurrentAsid(asid: u8) void {
    const pointer = readTlsPointer();
    if (pointer == 0) return;
    const percpu: *PerCpu = @ptrFromInt(pointer);
    percpu.current_asid = asid;
    if (builtin.cpu.arch == .loongarch64 and builtin.os.tag == .freestanding) {
        asm volatile ("csrwr %[v], 0x5"
            :
            : [v] "r" (@as(u64, asid)),
        );
    }
}

pub fn getCurrentAsid() u8 {
    const pointer = readTlsPointer();
    if (pointer == 0) return 0;
    const percpu: *PerCpu = @ptrFromInt(pointer);
    return percpu.current_asid;
}

comptime {
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        std.debug.assert(@offsetOf(PerCpu, "processor_number") == 8);
        std.debug.assert(@offsetOf(PerCpu, "current_thread_index") == 12);
    }
}
