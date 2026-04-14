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
// Module: src/hal/riscv64/sbi_hsm.zig
// SBI HSM - hart start/stop/status.
// Reference: RISC-V SBI Specification v2.0 (public).

pub const HSM_EID: u64 = 0x48534D;
pub const HART_START: u64 = 0;
pub const HART_STOP: u64 = 1;
pub const HART_GET_STATUS: u64 = 2;
pub const HART_SUSPEND: u64 = 3;

pub const HART_STATUS_NOT_PRESENT: u64 = 0;
pub const HART_STATUS_STARTED: u64 = 1;
pub const HART_STATUS_STARTING: u64 = 2;
pub const HART_STATUS_STOPPING: u64 = 3;
pub const HART_STATUS_STOPPED: u64 = 4;

pub fn hartStart(hartid: u64, start_addr: u64, priv: u64) i64 {
    const sbi = @import("sbi.zig");
    const ret = sbi.sbiCall(HSM_EID, HART_START, hartid, start_addr, priv);
    return ret.err;
}

pub fn hartStop() i64 {
    const sbi = @import("sbi.zig");
    const ret = sbi.sbiCall(HSM_EID, HART_STOP, 0, 0, 0);
    return ret.err;
}

pub fn hartGetStatus(hartid: u64) u64 {
    const sbi = @import("sbi.zig");
    const ret = sbi.sbiCall(HSM_EID, HART_GET_STATUS, hartid, 0, 0);
    if (ret.err != 0) return HART_STATUS_NOT_PRESENT;
    return @as(u64, @bitCast(ret.value));
}

pub fn hartSuspend(suspend_type: u64, resume_addr: u64, opaque_data: u64) i64 {
    const sbi = @import("sbi.zig");
    const ret = sbi.sbiCall(HSM_EID, HART_SUSPEND, suspend_type, resume_addr, opaque_data);
    return ret.err;
}

pub fn hsmAvailable() bool {
    const sbi = @import("sbi.zig");
    const ret = sbi.sbiCall(0x0, 0, 0, 0, 0);
    return ret.err == 0;
}

pub fn waitForHartStarted(hartid: u64, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 1) {
        const status = hartGetStatus(hartid);
        if (status == HART_STATUS_STARTED) return true;
        if (status == HART_STATUS_NOT_PRESENT) return false;
        var i: u32 = 0;
        while (i < 10000) : (i += 1) asm volatile ("");
    }
    return false;
}
