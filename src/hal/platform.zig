// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero — Centralized platform capability table.
// Purpose: Single source of truth for per-architecture HAL behaviour.
// Adding a new architecture: add one entry to each switch below and create
// the corresponding hal/<arch>/ implementation directory.
// Upper layers must import `hal.zig`, never this file directly.

const builtin = @import("builtin");

const Arch = builtin.target.cpu.arch;

// ---- Platform feature flags ----

pub const hasLegacyPCDevices = Arch == .x86_64;
pub const hasPS2Keyboard = Arch == .x86_64 or Arch == .loongarch64;
pub const hasPS2Mouse = Arch == .x86_64;
pub const hasDiscreteNvidiaGPU = Arch == .x86_64;
pub const hasDiscreteAMDGPU = Arch == .x86_64;
pub const hasIntelIGPU = Arch == .x86_64;
pub const hasLoongsonIGPU = Arch == .loongarch64;
pub const hasLegacyPCIBus = Arch == .x86_64;
pub const hasStandardPebTeb = Arch == .x86_64 or Arch == .riscv64;
pub fn supportsKuserShared() bool {
    return Arch == .x86_64;
}
pub fn supportsBootStorageProbe() bool {
    return Arch == .x86_64;
}
pub fn requiresSerialBootMenuWithoutHandoff() bool {
    return Arch == .loongarch64;
}

pub fn requiresEarlyKernelFrameReservation() bool {
    return Arch != .loongarch64;
}

pub fn processAddressSpaceUsesTag() bool {
    return Arch == .loongarch64;
}
pub fn processAddressSpaceRequiresKernelHalfLink() bool {
    return Arch == .x86_64 or Arch == .loongarch64 or Arch == .mips64el;
}

// ---- Platform strings ----

pub fn platformTimerDescription() []const u8 {
    return switch (Arch) {
        .x86_64 => "PIT",
        .loongarch64 => "LoongArch CSR",
        else => "arch tick",
    };
}

pub fn processorArchitectureNumber() u16 {
    return switch (Arch) {
        .x86_64 => 9,
        .loongarch64 => 0x6264,
        .aarch64 => 12,
        .riscv64 => 0x5064,
        else => 0,
    };
}

pub fn processorArchitectureName() []const u8 {
    return switch (Arch) {
        .x86_64 => "AMD64",
        .aarch64 => "ARM64",
        .loongarch64 => "LOONGARCH64",
        .riscv64 => "RISCV64",
        else => "UNKNOWN",
    };
}

pub fn targetArchName() []const u8 {
    return switch (Arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .riscv64 => "riscv64",
        .loongarch64 => "loongarch64",
        .mips64el => "mips64el",
        else => @tagName(Arch),
    };
}

// ---- VA policy ----

pub fn userVaRangeAllowed(va: u64, length: u64) bool {
    if (length == 0) return false;
    const last = va +% length -% 1;
    if (last < va) return false;
    return switch (Arch) {
        .x86_64 => va <= 0x0000_7FFF_FFFF_FFFF and last <= 0x0000_7FFF_FFFF_FFFF,
        else => true,
    };
}

// ---- Process TLB tags ----

pub fn allocateProcessAddressSpaceTag() u8 {
    if (Arch == .loongarch64 and builtin.os.tag == .freestanding) {
        return @import("loongarch64/tlb_flush.zig").allocateProcessAsid();
    }
    return 0;
}

pub fn processAddressSpaceTagVersion() u32 {
    if (Arch == .loongarch64 and builtin.os.tag == .freestanding) {
        return @import("loongarch64/tlb_flush.zig").getAsidVersion();
    }
    return 0;
}

// ---- CPU topology ----

pub fn logicalCpuCount() u32 {
    return switch (Arch) {
        .x86_64 => @import("x86_64/madt.zig").logical_cpu_count,
        .loongarch64 => @import("loongarch64/cpu_topology.zig").logicalCpuCount(),
        .riscv64 => @import("riscv64/cpu_topology.zig").logicalCpuCount(),
        .aarch64 => @import("aarch64/cpu_topology.zig").logicalCpuCount(),
        .mips64el => @import("mips64el/cpu_topology.zig").logicalCpuCount(),
        else => 1,
    };
}

// ---- High-resolution timers ----

pub fn readHighResolutionMonotonic() ?u64 {
    if (Arch == .x86_64) {
        const counter = @import("x86_64/hpet.zig").readMainCounterSafe();
        return if (counter != 0) counter else null;
    }
    return null;
}

pub fn readHighResolutionBootElapsedUs() ?u64 {
    if (Arch == .x86_64) {
        const hpet = @import("x86_64/hpet.zig");
        if (!hpet.hpet_usable) return null;
        const hz = hpet.hpet_counter_hz_approx;
        if (hz <= 0) return null;
        const now = hpet.readMainCounterSafe();
        if (now == 0) return null;
        const delta = now -% hpet.boot_counter_base;
        return delta / (hz / 1_000_000);
    }
    return null;
}

// ---- Interrupt / bring-up ----

pub fn enableBringupInterrupts() void {
    if (Arch == .loongarch64 or Arch == .riscv64 or Arch == .aarch64) {
        @import("../arch.zig").enableInterrupts();
    }
}

// ---- Power management ----

pub fn trySystemPowerOff() bool {
    if (Arch == .x86_64) {
        @import("x86_64/acpi_pm.zig").trySystemPowerOffAssumingS5Typ();
        return true;
    }
    return false;
}

// ---- Firmware framebuffer routing ----

pub fn pointRamfbToGuestPhys(phys: u64, width: u32, height: u32, stride: u32) bool {
    return switch (Arch) {
        .x86_64 => @import("x86_64/ramfb.zig").pointRamfbToGuestPhys(phys, width, height, stride),
        .aarch64 => @import("aarch64/ramfb.zig").pointRamfbToGuestPhys(phys, width, height, stride),
        .loongarch64 => @import("loongarch64/ramfb.zig").pointRamfbToGuestPhys(phys, width, height, stride),
        .riscv64 => @import("riscv64/ramfb.zig").pointRamfbToGuestPhys(phys, width, height, stride),
        .mips64el => blk: {
            @import("mips64el/ramfb.zig").pointRamfbToGuestPhys(phys);
            break :blk false;
        },
        else => false,
    };
}

pub fn remapFramebufferUncached(address: usize, length: usize) bool {
    const vm = @import("../mm/vm.zig");
    return vm.remapIdentityRangeUncached(address, length);
}

pub fn fenceScanoutVisibleWrites() void {
    @import("../arch.zig").memoryBarrier();
}

// ---- CPU spin / barrier ----

pub fn cpuRelax() void {
    @import("arch_dispatch.zig").spinCpuRelax();
}

pub fn compilerMemoryBarrier() void {
    @import("arch_dispatch.zig").memoryBarrier();
}
