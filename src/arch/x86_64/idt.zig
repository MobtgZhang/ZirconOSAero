//! x86_64 IDT (Interrupt Descriptor Table) setup
//! Reference: https://wiki.osdev.org/Interrupt_Descriptor_Table
//!
//! 主路径：**`syscall`/`sysret`**（`syscall_lstar.s` + `syscall_msr.zig`）。**Debug** 下 IDT 向量 **128**（`int 0x80`）登记专用桩，与 `syscall` 入口共用 `handleSyscall`；非 Debug 时 128 仍为默认桩。
//! **WOW64 / 兼容调用**：向量 **0x2E**（`int 0x2E`）经 `interrupt_x86` → `wow64_syscall.dispatchInt2e`；8259 重映射后硬件 IRQ 不占 0x2E（见 `hal/x86_64/pic.zig`）。

const builtin = @import("builtin");
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
        } else if (i == 128 and builtin.mode == .Debug) {
            idt_entries[i] = makeEntry(isr.int80DebugVectorStubAddr());
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
