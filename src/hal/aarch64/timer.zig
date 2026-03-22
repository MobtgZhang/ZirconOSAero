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
        : [result] "=r" (-> u64)
    );
}

pub fn getCounter() u64 {
    return asm ("mrs %[result], cntpct_el0"
        : [result] "=r" (-> u64)
    );
}

fn setCval(val: u64) void {
    asm volatile ("msr cntp_cval_el0, %[val]"
        :
        : [val] "r" (val)
    );
}

fn setCtl(val: u64) void {
    asm volatile ("msr cntp_ctl_el0, %[val]"
        :
        : [val] "r" (val)
    );
}

pub fn clearInterrupt() void {
    const cnt = getCounter();
    const freq = getFrequency();
    setCval(cnt + freq / 100);
}
