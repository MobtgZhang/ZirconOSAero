// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - HAL PCI configuration space abstraction
// Purpose: Hide platform-specific PCI config access behind one API so
// `drivers/bus/pcie.zig` never imports architecture folders directly.

const builtin = @import("builtin");
const vm = @import("../mm/vm.zig");

/// QEMU loongarch virt: `pci-host-ecam-generic` config space window.
const LOONGARCH_ECAM_BASE: u64 = 0x2000_0000;
/// QEMU aarch64 virt, low ECAM (`highmem-ecam=off`).
const AARCH64_ECAM_BASE: u64 = 0x3f00_0000;
/// QEMU riscv64 virt.
const RISCV64_ECAM_BASE: u64 = 0x3000_0000;
/// ECAM window size shared across non-PC QEMU virt targets (16 MiB, bus 0).
const ECAM_SIZE: u64 = 0x0100_0000;

pub const supports_pci_config: bool = builtin.target.cpu.arch == .x86_64 or
    builtin.target.cpu.arch == .loongarch64 or
    builtin.target.cpu.arch == .aarch64 or
    builtin.target.cpu.arch == .riscv64;

/// Read a 32-bit value from PCI configuration space.
pub fn readConfig32(bus_num: u8, device: u5, function: u3, offset: u8) u32 {
    if (!supports_pci_config) return 0xFFFF_FFFF;
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            const acpi_pci = @import("x86_64/acpi_pci_early.zig");
            if (acpi_pci.hasEcam()) {
                return acpi_pci.configRead32(bus_num, device, function, @as(u16, offset));
            }
            const portio = @import("x86_64/portio.zig");
            const cfg_addr = (0x8000_0000 |
                (@as(u32, bus_num) << 16) |
                (@as(u32, device) << 11) |
                (@as(u32, function) << 8) |
                offset) & 0xFF_FFFF_FC;
            portio.outl(0xCF8, cfg_addr);
            return portio.inl(0xCFC);
        },
        .loongarch64, .aarch64, .riscv64 => {
            const ecam_base: u64 = switch (builtin.target.cpu.arch) {
                .loongarch64 => LOONGARCH_ECAM_BASE,
                .aarch64 => AARCH64_ECAM_BASE,
                .riscv64 => RISCV64_ECAM_BASE,
                else => 0,
            };
            const addr = ecam_base +
                (@as(u64, bus_num) << 20) +
                (@as(u64, device) << 15) +
                (@as(u64, function) << 12) +
                offset;
            const ptr = @as(*volatile u32, @ptrFromInt(@as(usize, @intCast(addr))));
            return ptr.*;
        },
        else => return 0xFFFF_FFFF,
    }
}

/// Write a 32-bit value to PCI configuration space.
pub fn writeConfig32(bus_num: u8, device: u5, function: u3, offset: u8, value: u32) void {
    if (!supports_pci_config) return;
    switch (builtin.target.cpu.arch) {
        .x86_64 => {
            const acpi_pci = @import("x86_64/acpi_pci_early.zig");
            if (acpi_pci.hasEcam()) {
                acpi_pci.configWrite32(bus_num, device, function, @as(u16, offset), value);
                return;
            }
            const portio = @import("x86_64/portio.zig");
            const cfg_addr = (0x8000_0000 |
                (@as(u32, bus_num) << 16) |
                (@as(u32, device) << 11) |
                (@as(u32, function) << 8) |
                offset) & 0xFF_FFFF_FC;
            portio.outl(0xCF8, cfg_addr);
            portio.outl(0xCFC, value);
        },
        .loongarch64, .aarch64, .riscv64 => {
            const ecam_base: u64 = switch (builtin.target.cpu.arch) {
                .loongarch64 => LOONGARCH_ECAM_BASE,
                .aarch64 => AARCH64_ECAM_BASE,
                .riscv64 => RISCV64_ECAM_BASE,
                else => 0,
            };
            const addr = ecam_base +
                (@as(u64, bus_num) << 20) +
                (@as(u64, device) << 15) +
                (@as(u64, function) << 12) +
                offset;
            const ptr = @as(*volatile u32, @ptrFromInt(@as(usize, @intCast(addr))));
            ptr.* = value;
        },
        else => {},
    }
}

/// Map the platform ECAM window into the identity-mapped address space.
pub fn mapEcamIdentity() void {
    switch (builtin.target.cpu.arch) {
        .aarch64 => _ = vm.mapDeviceMmioIdentity(AARCH64_ECAM_BASE, ECAM_SIZE),
        .riscv64 => _ = vm.mapDeviceMmioIdentity(RISCV64_ECAM_BASE, ECAM_SIZE),
        .loongarch64 => _ = vm.mapDeviceMmioIdentity(LOONGARCH_ECAM_BASE, ECAM_SIZE),
        else => {},
    }
}

/// Diagnostic: which config access path is active (PC platform only).
pub fn configAccessKind() enum { unknown, legacy_port, ecam_mcfg } {
    if (builtin.target.cpu.arch != .x86_64) return .unknown;
    const acpi_pci = @import("x86_64/acpi_pci_early.zig");
    if (acpi_pci.hasEcam()) return .ecam_mcfg;
    return .legacy_port;
}
