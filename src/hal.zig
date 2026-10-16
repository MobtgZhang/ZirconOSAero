// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero — Unified HAL entry point.
// Purpose: Single import site for all platform-specific behaviour.
// Upper layers import `hal.zig`; per-architecture dispatch is in
// `hal/platform.zig` (capabilities) and `hal/<arch>/` (implementations).
// To add a new architecture:
//   1. Create `hal/<arch>/` with the implementation files.
//   2. Add one entry per switch in `hal/platform.zig`.
//   3. Add the arch to `hal/arch_dispatch.zig` (impl facade).
//   4. Add boot support in `hal/boot_dispatch.zig`.

const builtin = @import("builtin");
pub const platform = @import("hal/platform.zig");

// ---- Port I/O ----
pub const portio = if (builtin.target.cpu.arch == .x86_64)
    @import("hal/x86_64/portio.zig")
else
    struct {
        pub fn outb(_: u16, _: u8) void {}
        pub fn outw(_: u16, _: u16) void {}
        pub fn outl(_: u16, _: u32) void {}
        pub fn inb(_: u16) u8 {
            return 0;
        }
        pub fn inw(_: u16) u16 {
            return 0;
        }
        pub fn inl(_: u16) u32 {
            return 0;
        }
        pub fn ioWait() void {}
    };

// ---- Serial ----
pub const serial = if (builtin.target.cpu.arch == .x86_64)
    @import("hal/x86_64/serial.zig")
else
    struct {
        pub fn isReady() bool {
            return false;
        }
        pub fn hasData() bool {
            return false;
        }
        pub fn readByte() ?u8 {
            return null;
        }
        pub fn writeByte(_: u8) void {}
    };

// ---- Firmware framebuffer ----
pub const pointRamfbToGuestPhys = platform.pointRamfbToGuestPhys;
pub const remapFramebufferUncached = platform.remapFramebufferUncached;
pub const fenceScanoutVisibleWrites = platform.fenceScanoutVisibleWrites;

// ---- Platform capabilities ----
pub const hasLegacyPCDevices = platform.hasLegacyPCDevices;
pub const hasPS2Keyboard = platform.hasPS2Keyboard;
pub const hasPS2Mouse = platform.hasPS2Mouse;
pub const hasDiscreteNvidiaGPU = platform.hasDiscreteNvidiaGPU;
pub const hasDiscreteAMDGPU = platform.hasDiscreteAMDGPU;
pub const hasIntelIGPU = platform.hasIntelIGPU;
pub const hasLoongsonIGPU = platform.hasLoongsonIGPU;
pub const hasLegacyPCIBus = platform.hasLegacyPCIBus;
pub const hasStandardPebTeb = platform.hasStandardPebTeb;
pub const supportsKuserShared = platform.supportsKuserShared;
pub const supportsBootStorageProbe = platform.supportsBootStorageProbe;
pub const requiresSerialBootMenuWithoutHandoff = platform.requiresSerialBootMenuWithoutHandoff;
pub const requiresEarlyKernelFrameReservation = platform.requiresEarlyKernelFrameReservation;
pub const processAddressSpaceUsesTag = platform.processAddressSpaceUsesTag;
pub const processAddressSpaceRequiresKernelHalfLink =
    platform.processAddressSpaceRequiresKernelHalfLink;

// ---- Strings ----
pub const platformTimerDescription = platform.platformTimerDescription;
pub const processorArchitectureNumber = platform.processorArchitectureNumber;
pub const processorArchitectureName = platform.processorArchitectureName;
pub const targetArchName = platform.targetArchName;

// ---- VA policy ----
pub const userVaRangeAllowed = platform.userVaRangeAllowed;

// ---- Process TLB tags ----
pub const allocateProcessAddressSpaceTag = platform.allocateProcessAddressSpaceTag;
pub const processAddressSpaceTagVersion = platform.processAddressSpaceTagVersion;

// ---- CPU topology ----
pub const logicalCpuCount = platform.logicalCpuCount;

// ---- Timers ----
pub const readHighResolutionMonotonic = platform.readHighResolutionMonotonic;
pub const readHighResolutionBootElapsedUs = platform.readHighResolutionBootElapsedUs;

// ---- Interrupts ----
pub const enableBringupInterrupts = platform.enableBringupInterrupts;

// ---- Power ----
pub const trySystemPowerOff = platform.trySystemPowerOff;

// ---- CPU spin / barrier ----
pub const cpuRelax = platform.cpuRelax;
pub const compilerMemoryBarrier = platform.compilerMemoryBarrier;
