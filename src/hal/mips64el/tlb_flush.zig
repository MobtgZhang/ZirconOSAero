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

//! MIPS64EL TLB flush helpers — aligned with x86/LoongArch SMP broadcast interface.

const paging = @import("../../arch/mips64el/paging.zig");

var pending_global_shootdown: bool = false;

pub fn notePendingGlobalShootdown() void {
    pending_global_shootdown = true;
}

pub fn pendingShootdownHint() bool {
    const was = pending_global_shootdown;
    pending_global_shootdown = false;
    return was;
}

pub fn noteUserMappingInvalidatedSmp(_va: u64) void {
    // SMP TLB shootdown: on multi-core, send IPI to other cores.
    // Single-core stub — local invalidation only.
    paging.invtlbAddrVa(_va);
}

pub fn requestGlobalFlushStub() void {
    paging.invtlbAll();
    pending_global_shootdown = false;
}
