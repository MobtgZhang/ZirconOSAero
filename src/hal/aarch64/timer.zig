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

//! ARM Generic Timer driver for AArch64
//! Uses the EL1 physical timer (CNTP_*)

pub fn init() void {
    const freq = getFrequency();
    const interval = freq / 100;
    setCval(interval);
    setCtl(1);
}

pub fn getFrequency() u64 {
    return asm ("mrs %[result], cntfrq_el0"
        : [result] "=r" (-> u64),
    );
}

pub fn getCounter() u64 {
    return asm ("mrs %[result], cntpct_el0"
        : [result] "=r" (-> u64),
    );
}

fn setCval(val: u64) void {
    asm volatile ("msr cntp_cval_el0, %[val]"
        :
        : [val] "r" (val),
    );
}

fn setCtl(val: u64) void {
    asm volatile ("msr cntp_ctl_el0, %[val]"
        :
        : [val] "r" (val),
    );
}

pub fn clearInterrupt() void {
    const cnt = getCounter();
    const freq = getFrequency();
    setCval(cnt + freq / 100);
}
