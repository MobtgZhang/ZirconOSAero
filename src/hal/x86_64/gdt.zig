//! x86_64 GDT (Global Descriptor Table) and TSS (Task State Segment)
//! Sets up kernel/user segments and task state for Ring 0/3 transitions

const GdtEntry = packed struct(u64) {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_mid: u8 = 0,
    access: u8 = 0,
    flags_limit_high: u8 = 0,
    base_high: u8 = 0,
};

pub const Tss = extern struct {
    reserved0: u32 align(1) = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    ist1: u64 align(1) = 0,
    ist2: u64 align(1) = 0,
    ist3: u64 align(1) = 0,
    ist4: u64 align(1) = 0,
    ist5: u64 align(1) = 0,
    ist6: u64 align(1) = 0,
    ist7: u64 align(1) = 0,
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    iopb_offset: u16 align(1) = 104,
};

pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_CS: u16 = 0x1B;
pub const USER_DS: u16 = 0x23;
pub const TSS_SEL: u16 = 0x28;

const GDT_ENTRIES = 7;
var gdt: [GDT_ENTRIES]GdtEntry align(16) = undefined;
var tss: Tss = .{};

const GdtDescriptor = packed struct {
    limit: u16,
    base: u64,
};

fn makeEntry(base: u32, limit: u20, access: u8, flags: u4) GdtEntry {
    return .{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_mid = @truncate(base >> 16),
        .access = access,
        .flags_limit_high = (@as(u8, flags) << 4) | @as(u8, @truncate(limit >> 16)),
        .base_high = @truncate(base >> 24),
    };
}

pub fn init(kernel_stack: u64) void {
    gdt[0] = .{};
    gdt[1] = makeEntry(0, 0xFFFFF, 0x9A, 0xA);
    gdt[2] = makeEntry(0, 0xFFFFF, 0x92, 0xC);
    gdt[3] = makeEntry(0, 0xFFFFF, 0xFA, 0xA);
    gdt[4] = makeEntry(0, 0xFFFFF, 0xF2, 0xC);

    setupTss(kernel_stack);

    const tss_base = @intFromPtr(&tss);
    const tss_limit: u20 = @intCast(@sizeOf(Tss) - 1);

    gdt[5] = .{
        .limit_low = @truncate(tss_limit),
        .base_low = @truncate(tss_base),
        .base_mid = @truncate(tss_base >> 16),
        .access = 0x89,
        .flags_limit_high = @as(u8, @truncate(tss_limit >> 16)),
        .base_high = @truncate(tss_base >> 24),
    };

    gdt[6] = @bitCast(@as(u64, @truncate(tss_base >> 32)));

    loadGdt();
    loadTss();
}

fn setupTss(kernel_stack: u64) void {
    tss = .{};
    tss.rsp0 = kernel_stack;
    tss.iopb_offset = @intCast(@sizeOf(Tss));
}

pub fn setKernelStack(stack: u64) void {
    tss.rsp0 = stack;
}

extern fn load_gdt_flush(desc: *const GdtDescriptor) void;
extern fn load_tss_reg(selector: u16) void;

fn loadGdt() void {
    const desc = GdtDescriptor{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };
    load_gdt_flush(&desc);
}

fn loadTss() void {
    load_tss_reg(TSS_SEL);
}
