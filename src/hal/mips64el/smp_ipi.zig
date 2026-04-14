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

//! MIPS64EL IPI (Inter-Processor Interrupt) stub for Loongson 3A platforms.
//! Loongson 3A uses platform-specific mailbox registers, not standard MIPS mechanism.

const paging = @import("../../arch/mips64el/paging.zig");

pub fn broadcastFullTlbShootdownStub() void {
    // Single-core: local TLB flush only.
    paging.invtlbAll();
}

pub fn clearLocalIpi() void {
    // Stub: Loongson IPI clear would write to platform-specific MMIO register.
}

pub fn handleIpiInterrupt() void {
    // On receiving IPI from another core: flush local TLB.
    paging.invtlbAll();
    clearLocalIpi();
}
