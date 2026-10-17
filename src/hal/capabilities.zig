// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero — Pure HAL capability table.
// This module deliberately has no kernel implementation dependencies so SDK
// ABI modules and host tests can consume platform facts without pulling in
// boot, memory, or device driver code.

const builtin = @import("builtin");

const Arch = builtin.target.cpu.arch;

pub const hasLegacyPCDevices = Arch == .x86_64;
pub const hasPS2Keyboard = Arch == .x86_64 or Arch == .loongarch64;
pub const hasPS2Mouse = Arch == .x86_64;
pub const hasDiscreteNvidiaGPU = Arch == .x86_64;
pub const hasDiscreteAMDGPU = Arch == .x86_64;
pub const hasIntelIGPU = Arch == .x86_64;
pub const hasLoongsonIGPU = Arch == .loongarch64;
pub const hasLegacyPCIBus = Arch == .x86_64;
pub const hasStandardPebTeb = Arch == .x86_64 or Arch == .riscv64;
pub const supportsUserPebTebStubVa =
    Arch == .x86_64 or Arch == .loongarch64 or Arch == .riscv64;
pub const wow64UsesNativeAddressSpace = Arch == .x86_64;
pub const wow64UsesLoongArchTranslation = Arch == .loongarch64;
pub const wow64UsesRiscVTranslation = Arch == .riscv64;
pub const wow64UsesArmTranslation = Arch == .aarch64;
pub const wow64UsesMipsTranslation = Arch == .mips64el;

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

pub const peMachineI386: u16 = 0x014C;
pub const peMachineAmd64: u16 = 0x8664;
pub const peMachineArm64: u16 = 0xAA64;
pub const peMachineLoongArch64: u16 = 0x6264;
pub const peMachineRiscV64: u16 = 0x5064;

pub fn nativePeMachineType() u16 {
    return switch (Arch) {
        .x86_64 => peMachineAmd64,
        .loongarch64 => peMachineLoongArch64,
        .aarch64 => peMachineArm64,
        .riscv64 => peMachineRiscV64,
        else => peMachineAmd64,
    };
}

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
        .loongarch64 => peMachineLoongArch64,
        .aarch64 => 12,
        .riscv64 => peMachineRiscV64,
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

pub fn userVaRangeAllowed(va: u64, length: u64) bool {
    if (length == 0) return false;
    const last = va +% length -% 1;
    if (last < va) return false;
    return switch (Arch) {
        .x86_64 => va <= 0x0000_7FFF_FFFF_FFFF and last <= 0x0000_7FFF_FFFF_FFFF,
        else => true,
    };
}
