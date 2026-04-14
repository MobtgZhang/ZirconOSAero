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

//! SBI (Supervisor Binary Interface) calls for RISC-V 64.
//! S-mode cannot directly access CLINT; timer and IPI go through OpenSBI ecall.
//! Ref: RISC-V SBI Specification v2.0 (riscv-non-isa/riscv-sbi-doc, public).

pub const SBI_SUCCESS: i64 = 0;

const SbiRet = struct { err: i64, value: i64 };

fn sbiCall(eid: u64, fid: u64, a0: u64, a1: u64, a2: u64) SbiRet {
    var err: i64 = undefined;
    var val: i64 = undefined;
    asm volatile ("ecall"
        : [e] "={a0}" (err),
          [v] "={a1}" (val),
        : [a0] "{a0}" (a0),
          [a1] "{a1}" (a1),
          [a2] "{a2}" (a2),
          [a6] "{a6}" (fid),
          [a7] "{a7}" (eid),
        : .{ .memory = true });
    return .{ .err = err, .value = val };
}

/// SBI TIME extension (EID 0x54494D45, FID 0): set next timer interrupt.
pub fn setTimer(stime_value: u64) void {
    _ = sbiCall(0x54494D45, 0, stime_value, 0, 0);
}

/// Read `time` CSR (alias for `rdtime`).
pub fn readTime() u64 {
    return asm volatile ("rdtime %[r]"
        : [r] "=r" (-> u64),
    );
}
