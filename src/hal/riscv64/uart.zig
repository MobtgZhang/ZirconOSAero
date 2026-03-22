//! SBI console driver for RISC-V 64
//! Uses SBI legacy putchar (EID=0x01) and DBCN extension for output

pub fn init() void {}

fn sbiPutchar(ch: u8) void {
    asm volatile ("ecall"
        :
        : [ch] "{a0}" (@as(u64, ch)),
          [eid] "{a7}" (@as(u64, 0x01)),
    );
}

pub fn write(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') sbiPutchar('\r');
        sbiPutchar(c);
    }
}
