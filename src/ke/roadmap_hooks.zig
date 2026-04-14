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
