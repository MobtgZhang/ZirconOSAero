// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/smp_boot.zig
// Purpose: AP **INIT/SIPI**、低 1MiB 长模式跳板安装、按 MADT APIC ID 单发 SIPI（`lapic_smp.initAndSipiPerApicId`）。
//
// This is an independent clean-room implementation.
// Reference: Intel SDM / ACPI MADT；[docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) K2.4

const klog = @import("../../rtl/klog.zig");
const madt = @import("madt.zig");
const lapic_smp = @import("lapic_smp.zig");
const vm = @import("../../mm/vm.zig");
const ap_trampoline = @import("ap_trampoline.zig");
const ap_entry = @import("ap_entry.zig");

pub fn tryStartApplicationProcessorsStub() void {
    const n = madt.logical_cpu_count;
    if (n <= 1) return;

    const ks = vm.kernelAddressSpace() orelse {
        klog.warn("SMP: no kernel address space; skip AP boot", .{});
        return;
    };

    ap_entry.resetApBootSequence();
    ap_entry.prepareApStacksAndTssRsp0();

    ap_trampoline.writeTrampolinePage(lapic_smp.ap_trampoline_page_phys, @truncate(ks.pml4_phys), ap_entry.apTrampolineIntermediateRip());

    klog.info("SMP: trampoline phys=0x%x cr3=0x%x entry=0x%x — INIT+SIPI (per APIC ID)", .{
        lapic_smp.ap_trampoline_page_phys,
        @as(u32, @truncate(ks.pml4_phys)),
        @as(u32, @truncate(ap_entry.apTrampolineIntermediateRip())),
    });

    lapic_smp.initAndSipiPerApicId();
    klog.info("SMP: logical_cpus=%u — per-APIC INIT+SIPI×2 done", .{n});
}
