//! x86_64 IDT (Interrupt Descriptor Table) setup
//! Reference: https://wiki.osdev.org/Interrupt_Descriptor_Table
//!
//! 用户态系统调用仅经 **`syscall`/`sysret`**（`syscall_lstar.s` + `syscall_msr.zig`）。IDT 向量 **128** 与其它未用向量相同，指向默认桩（**不**再作为 syscall 入口）。

const isr = @import("isr.zig");

const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};

const IdtDescriptor = packed struct {
    limit: u16,
    base: u64,
};

const KERNEL_CS: u16 = 0x08;
const GATE_ATTR: u8 = 0x8E;

var idt_entries: [256]IdtEntry = undefined;

fn makeEntry(addr: usize) IdtEntry {
    return .{
        .offset_low = @truncate(addr),
        .selector = KERNEL_CS,
        .ist = 0,
        .type_attr = GATE_ATTR,
        .offset_mid = @truncate(addr >> 16),
        .offset_high = @truncate(addr >> 32),
    };
}

pub fn init() void {
    const default_addr = isr.getDefaultAddr();

    var i: usize = 0;
    while (i < isr.STUB_COUNT) : (i += 1) {
        idt_entries[i] = makeEntry(isr.getStubAddr(i));
    }
    while (i < 256) : (i += 1) {
        if (i == isr.ipi_tlb_flush_vector) {
            idt_entries[i] = makeEntry(isr.ipiTlbFlushStubAddr());
        } else {
            idt_entries[i] = makeEntry(default_addr);
        }
    }

    var desc = IdtDescriptor{
        .limit = @sizeOf(@TypeOf(idt_entries)) - 1,
        .base = @intFromPtr(&idt_entries),
    };

    loadIdt(&desc);
}

/// AP 与 BSP 共用同一 `idt_entries` 映像（恒等映射下物理地址一致）。
pub fn reloadKernelIdt() void {
    const desc = IdtDescriptor{
        .limit = @sizeOf(@TypeOf(idt_entries)) - 1,
        .base = @intFromPtr(&idt_entries),
    };
    loadIdt(&desc);
}

extern fn load_idt(desc: *const IdtDescriptor) void;

fn loadIdt(desc: *const IdtDescriptor) void {
    load_idt(desc);
}
