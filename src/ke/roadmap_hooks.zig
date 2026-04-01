// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/roadmap_hooks.zig
// Purpose: 路线图占位（SMP / 网络 / 存储 / POSIX / ACPI / 真机验证）— 编译期拉取，避免“未引用即不编译”漂移。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.

pub const SmpPhase = enum { not_started, planned, bringup };
pub const NetPhase = enum { not_started, planned, virtio_net };
pub const StoragePhase = enum { not_started, planned, ahci_nvme };
pub const PosixPhase = enum { not_started, planned, musl };
pub const AcpiPhase = enum { not_started, planned, rsdp_mcfg_walk, acpica };
pub const HwBringupPhase = enum { qemu_only, uefi_real_hw };

pub fn smpStatus() SmpPhase {
    return .planned;
}

pub fn netStatus() NetPhase {
    return .planned;
}

pub fn storageStatus() StoragePhase {
    return .planned;
}

pub fn posixStatus() PosixPhase {
    return .planned;
}

pub fn acpiStatus() AcpiPhase {
    return .rsdp_mcfg_walk;
}

pub fn hwBringupStatus() HwBringupPhase {
    return .qemu_only;
}
