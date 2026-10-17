// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero — HAL implementation facade.
// Pure platform facts live in `capabilities.zig`; this facade binds them to
// architecture implementations. Upper layers must import `hal.zig`.

const builtin = @import("builtin");

pub const capabilities = @import("hal_capabilities");

const Arch = builtin.target.cpu.arch;

pub const hasLegacyPCDevices = capabilities.hasLegacyPCDevices;
pub const hasPS2Keyboard = capabilities.hasPS2Keyboard;
pub const hasPS2Mouse = capabilities.hasPS2Mouse;
pub const hasDiscreteNvidiaGPU = capabilities.hasDiscreteNvidiaGPU;
pub const hasDiscreteAMDGPU = capabilities.hasDiscreteAMDGPU;
pub const hasIntelIGPU = capabilities.hasIntelIGPU;
pub const hasLoongsonIGPU = capabilities.hasLoongsonIGPU;
pub const hasLegacyPCIBus = capabilities.hasLegacyPCIBus;
pub const hasStandardPebTeb = capabilities.hasStandardPebTeb;
pub const supportsUserPebTebStubVa = capabilities.supportsUserPebTebStubVa;
pub const wow64UsesNativeAddressSpace = capabilities.wow64UsesNativeAddressSpace;
pub const wow64UsesLoongArchTranslation = capabilities.wow64UsesLoongArchTranslation;
pub const wow64UsesRiscVTranslation = capabilities.wow64UsesRiscVTranslation;
pub const wow64UsesArmTranslation = capabilities.wow64UsesArmTranslation;
pub const wow64UsesMipsTranslation = capabilities.wow64UsesMipsTranslation;

pub const supportsKuserShared = capabilities.supportsKuserShared;
pub const supportsBootStorageProbe = capabilities.supportsBootStorageProbe;
pub const requiresSerialBootMenuWithoutHandoff =
    capabilities.requiresSerialBootMenuWithoutHandoff;
pub const requiresEarlyKernelFrameReservation =
    capabilities.requiresEarlyKernelFrameReservation;
pub const processAddressSpaceUsesTag = capabilities.processAddressSpaceUsesTag;
pub const processAddressSpaceRequiresKernelHalfLink =
    capabilities.processAddressSpaceRequiresKernelHalfLink;

pub const peMachineI386 = capabilities.peMachineI386;
pub const peMachineAmd64 = capabilities.peMachineAmd64;
pub const peMachineArm64 = capabilities.peMachineArm64;
pub const peMachineLoongArch64 = capabilities.peMachineLoongArch64;
pub const peMachineRiscV64 = capabilities.peMachineRiscV64;
pub const nativePeMachineType = capabilities.nativePeMachineType;

pub const platformTimerDescription = capabilities.platformTimerDescription;
pub const processorArchitectureNumber = capabilities.processorArchitectureNumber;
pub const processorArchitectureName = capabilities.processorArchitectureName;
pub const targetArchName = capabilities.targetArchName;
pub const userVaRangeAllowed = capabilities.userVaRangeAllowed;

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

pub fn enableBringupInterrupts() void {
    if (Arch == .loongarch64 or Arch == .riscv64 or Arch == .aarch64) {
        @import("../arch.zig").enableInterrupts();
    }
}

pub fn trySystemPowerOff() bool {
    if (Arch == .x86_64) {
        @import("x86_64/acpi_pm.zig").trySystemPowerOffAssumingS5Typ();
        return true;
    }
    return false;
}

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
    return @import("../mm/vm.zig").remapIdentityRangeUncached(address, length);
}

pub fn fenceScanoutVisibleWrites() void {
    @import("../arch.zig").memoryBarrier();
}

pub fn cpuRelax() void {
    @import("arch_dispatch.zig").spinCpuRelax();
}

pub fn compilerMemoryBarrier() void {
    @import("arch_dispatch.zig").memoryBarrier();
}
