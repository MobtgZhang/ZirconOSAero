//! RISC-V 64 CPU topology stub.
//! QEMU virt with -smp N provides N harts; for now single-hart boot only.
//! Future: parse DTB or SBI HSM to enumerate online harts.

var cpu_count: u32 = 1;

pub fn logicalCpuCount() u32 {
    return cpu_count;
}

pub fn setLogicalCpuCount(n: u32) void {
    cpu_count = if (n == 0) 1 else n;
}
