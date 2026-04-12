// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/mips64_engine_stub.zig
// Purpose: MIPS64EL Dynamic Binary Translation Engine for x86-32/x86-64 code.
// This is an independent clean-room implementation.
// Loongson 3A has no hardware binary translation; pure-software DBT required.

const builtin = @import("builtin");
const klog = @import("../../../rtl/klog.zig");
const ntdll = @import("../../../libs/ntdll.zig");
const tlb_cache = @import("tlb_cache.zig");
const decoder = @import("x86_decoder.zig");
const ir = @import("ir.zig");
const types = @import("types.zig");

pub const EngineState = enum {
    uninitialized,
    initializing,
    available,
    not_available,
    engine_error,
};

var engine_state: EngineState = .uninitialized;
var translation_cache: tlb_cache.TranslationCache = undefined;

pub const EngineFeatures = packed struct(u32) {
    has_mips32r2: bool,
    has_mips64r2: bool,
    has_dsp: bool,
    uses_software_decoder: bool,
    uses_tb_cache: bool,
    uses_eflags_emulation: bool,
    uses_delay_slot: bool,
    reserved: u24,
};

var engine_features: EngineFeatures = .{
    .has_mips32r2 = false,
    .has_mips64r2 = false,
    .has_dsp = false,
    .uses_software_decoder = true,
    .uses_tb_cache = true,
    .uses_eflags_emulation = true,
    .uses_delay_slot = true,
    .reserved = 0,
};

var total_translations: u64 = 0;
var total_translated_insns: u64 = 0;
var total_cache_hits: u64 = 0;
var total_page_faults: u64 = 0;
var total_delay_slots: u64 = 0;
var total_syscalls: u64 = 0;
var total_native_calls: u64 = 0;

pub const MIPS64_REG = enum(u8) {
    r0,
    r1,
    r2,
    r3,
    r4,
    r5,
    r6,
    r7,
    r8,
    r9,
    r10,
    r11,
    r12,
    r13,
    r14,
    r15,
    r16,
    r17,
    r18,
    r19,
    r20,
    r21,
    r22,
    r23,
    r24,
    r25,
    r26,
    r27,
    r28,
    r29,
    r30,
    r31,
};

pub const X86RegToMIPS64Map = struct {
    pub const EAX: MIPS64_REG = .r2;
    pub const ECX: MIPS64_REG = .r9;
    pub const EDX: MIPS64_REG = .r3;
    pub const EBX: MIPS64_REG = .r16;
    pub const ESP: MIPS64_REG = .r29;
    pub const EBP: MIPS64_REG = .r17;
    pub const ESI: MIPS64_REG = .r18;
    pub const EDI: MIPS64_REG = .r19;

    pub fn fromX86Reg8(reg: u8) MIPS64_REG {
        return switch (reg) {
            0 => .r2,
            1 => .r9,
            2 => .r3,
            3 => .r16,
            4 => .r2,
            5 => .r9,
            6 => .r3,
            7 => .r16,
            else => .r0,
        };
    }

    pub fn fromX86Reg32(reg: u8) MIPS64_REG {
        return switch (reg) {
            0 => .r2,
            1 => .r9,
            2 => .r3,
            3 => .r16,
            4 => .r29,
            5 => .r17,
            6 => .r18,
            7 => .r19,
            else => .r0,
        };
    }
};

pub const MIPS64CodeGen = struct {
    code_buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) MIPS64CodeGen {
        return .{
            .code_buf = buf,
            .pos = 0,
        };
    }

    fn emit32(self: *MIPS64CodeGen, value: u32) void {
        if (self.pos + 4 <= self.code_buf.len) {
            self.code_buf[self.pos .. self.pos + 4].* = @as([4]u8, @bitCast(@as(u32, @byteSwap(value))));
            self.pos += 4;
        }
    }

    fn emitOpcode(self: *MIPS64CodeGen, opcode: u6, rs: u5, rt: u5, rd: u5, shamt: u5, funct: u6) void {
        const instr: u32 = (@as(u32, opcode) << 26) | (@as(u32, rs) << 21) |
            (@as(u32, rt) << 16) | (@as(u32, rd) << 11) |
            (@as(u32, shamt) << 6) | funct;
        self.emit32(instr);
    }

    fn emitImmediate(self: *MIPS64CodeGen, opcode: u6, rs: u5, rt: u5, imm: i16) void {
        const instr: u32 = (@as(u32, opcode) << 26) | (@as(u32, rs) << 21) |
            (@as(u32, rt) << 16) | @as(u32, @bitCast(imm));
        self.emit32(instr);
    }

    fn emitJump(self: *MIPS64CodeGen, opcode: u6, target: u26) void {
        const instr: u32 = (@as(u32, opcode) << 26) | target;
        self.emit32(instr);
    }

    fn emitRegimm(self: *MIPS64CodeGen, opcode: u6, rs: u5, rt: u5, imm: i16) void {
        const instr: u32 = (@as(u32, opcode) << 26) | (@as(u32, rs) << 21) |
            (@as(u32, rt) << 16) | @as(u32, @bitCast(imm));
        self.emit32(instr);
    }

    pub fn genNop(self: *MIPS64CodeGen) void {
        self.emit32(0x00000000);
    }

    pub fn genAdd(self: *MIPS64CodeGen, rd: u5, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 0x20);
    }

    pub fn genAddu(self: *MIPS64CodeGen, rd: u5, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 0x21);
    }

    pub fn genSub(self: *MIPS64CodeGen, rd: u5, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 0x22);
    }

    pub fn genSubu(self: *MIPS64CodeGen, rd: u5, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 0x23);
    }

    pub fn genAnd(self: *MIPS64CodeGen, rd: u5, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 0x24);
    }

    pub fn genOr(self: *MIPS64CodeGen, rd: u5, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 0x25);
    }

    pub fn genXor(self: *MIPS64CodeGen, rd: u5, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 0x26);
    }

    pub fn genNor(self: *MIPS64CodeGen, rd: u5, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 0x27);
    }

    pub fn genSlt(self: *MIPS64CodeGen, rd: u5, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 0x2A);
    }

    pub fn genSltu(self: *MIPS64CodeGen, rd: u5, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 0x2B);
    }

    pub fn genSll(self: *MIPS64CodeGen, rd: u5, rt: u5, shamt: u5) void {
        self.emitOpcode(0, 0, rt, rd, shamt, 0);
    }

    pub fn genSrl(self: *MIPS64CodeGen, rd: u5, rt: u5, shamt: u5) void {
        self.emitOpcode(0, 0, rt, rd, shamt, 2);
    }

    pub fn genSra(self: *MIPS64CodeGen, rd: u5, rt: u5, shamt: u5) void {
        self.emitOpcode(0, 0, rt, rd, shamt, 3);
    }

    pub fn genSllv(self: *MIPS64CodeGen, rd: u5, rt: u5, rs: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 4);
    }

    pub fn genSrlv(self: *MIPS64CodeGen, rd: u5, rt: u5, rs: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 6);
    }

    pub fn genSrav(self: *MIPS64CodeGen, rd: u5, rt: u5, rs: u5) void {
        self.emitOpcode(0, rs, rt, rd, 0, 7);
    }

    pub fn genJr(self: *MIPS64CodeGen, rs: u5) void {
        self.emitOpcode(0, rs, 0, 0, 0, 8);
    }

    pub fn genJalr(self: *MIPS64CodeGen, rd: u5, rs: u5) void {
        self.emitOpcode(0, rs, 0, rd, 0, 9);
    }

    pub fn genSyscall(self: *MIPS64CodeGen) void {
        self.emit32(0x0000000C);
    }

    pub fn genBreak(self: *MIPS64CodeGen) void {
        self.emit32(0x0000000D);
    }

    pub fn genSync(self: *MIPS64CodeGen) void {
        self.emitOpcode(0, 0, 0, 0, 0, 0x0F);
    }

    pub fn genMfhi(self: *MIPS64CodeGen, rd: u5) void {
        self.emitOpcode(0, 0, 0, rd, 0, 0x10);
    }

    pub fn genMthi(self: *MIPS64CodeGen, rs: u5) void {
        self.emitOpcode(0, rs, 0, 0, 0, 0x11);
    }

    pub fn genMflo(self: *MIPS64CodeGen, rd: u5) void {
        self.emitOpcode(0, 0, 0, rd, 0, 0x12);
    }

    pub fn genMtlo(self: *MIPS64CodeGen, rs: u5) void {
        self.emitOpcode(0, rs, 0, 0, 0, 0x13);
    }

    pub fn genMult(self: *MIPS64CodeGen, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, 0, 0, 0x18);
    }

    pub fn genMultu(self: *MIPS64CodeGen, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, 0, 0, 0x19);
    }

    pub fn genDiv(self: *MIPS64CodeGen, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, 0, 0, 0x1A);
    }

    pub fn genDivu(self: *MIPS64CodeGen, rs: u5, rt: u5) void {
        self.emitOpcode(0, rs, rt, 0, 0, 0x1B);
    }

    pub fn genAddi(self: *MIPS64CodeGen, rt: u5, rs: u5, imm: i16) void {
        self.emitImmediate(0x08, rs, rt, imm);
    }

    pub fn genAddiu(self: *MIPS64CodeGen, rt: u5, rs: u5, imm: i16) void {
        self.emitImmediate(0x09, rs, rt, imm);
    }

    pub fn genAndi(self: *MIPS64CodeGen, rt: u5, rs: u5, imm: u16) void {
        self.emitImmediate(0x0C, rs, rt, @bitCast(imm));
    }

    pub fn genOri(self: *MIPS64CodeGen, rt: u5, rs: u5, imm: u16) void {
        self.emitImmediate(0x0D, rs, rt, @bitCast(imm));
    }

    pub fn genXori(self: *MIPS64CodeGen, rt: u5, rs: u5, imm: u16) void {
        self.emitImmediate(0x0E, rs, rt, @bitCast(imm));
    }

    pub fn genLui(self: *MIPS64CodeGen, rt: u5, imm: u16) void {
        self.emitImmediate(0x0F, 0, rt, @bitCast(imm));
    }

    pub fn genSlti(self: *MIPS64CodeGen, rt: u5, rs: u5, imm: i16) void {
        self.emitImmediate(0x0A, rs, rt, imm);
    }

    pub fn genSltiu(self: *MIPS64CodeGen, rt: u5, rs: u5, imm: i16) void {
        self.emitImmediate(0x0B, rs, rt, imm);
    }

    pub fn genLb(self: *MIPS64CodeGen, rt: u5, rs: u5, offset: i16) void {
        self.emitImmediate(0x20, rs, rt, offset);
    }

    pub fn genLh(self: *MIPS64CodeGen, rt: u5, rs: u5, offset: i16) void {
        self.emitImmediate(0x21, rs, rt, offset);
    }

    pub fn genLw(self: *MIPS64CodeGen, rt: u5, rs: u5, offset: i16) void {
        self.emitImmediate(0x23, rs, rt, offset);
    }

    pub fn genLbu(self: *MIPS64CodeGen, rt: u5, rs: u5, offset: i16) void {
        self.emitImmediate(0x24, rs, rt, offset);
    }

    pub fn genLhu(self: *MIPS64CodeGen, rt: u5, rs: u5, offset: i16) void {
        self.emitImmediate(0x25, rs, rt, offset);
    }

    pub fn genLwu(self: *MIPS64CodeGen, rt: u5, rs: u5, offset: i16) void {
        self.emitImmediate(0x27, rs, rt, offset);
    }

    pub fn genLd(self: *MIPS64CodeGen, rt: u5, rs: u5, offset: i16) void {
        self.emitImmediate(0x37, rs, rt, offset);
    }

    pub fn genSb(self: *MIPS64CodeGen, rt: u5, rs: u5, offset: i16) void {
        self.emitImmediate(0x28, rs, rt, offset);
    }

    pub fn genSh(self: *MIPS64CodeGen, rt: u5, rs: u5, offset: i16) void {
        self.emitImmediate(0x29, rs, rt, offset);
    }

    pub fn genSw(self: *MIPS64CodeGen, rt: u5, rs: u5, offset: i16) void {
        self.emitImmediate(0x2B, rs, rt, offset);
    }

    pub fn genSd(self: *MIPS64CodeGen, rt: u5, rs: u5, offset: i16) void {
        self.emitImmediate(0x3F, rs, rt, offset);
    }

    pub fn genBeq(self: *MIPS64CodeGen, rs: u5, rt: u5, offset: i16) void {
        self.emitImmediate(0x04, rs, rt, offset);
    }

    pub fn genBne(self: *MIPS64CodeGen, rs: u5, rt: u5, offset: i16) void {
        self.emitImmediate(0x05, rs, rt, offset);
    }

    pub fn genBgtz(self: *MIPS64CodeGen, rs: u5, offset: i16) void {
        self.emitImmediate(0x07, rs, 1, offset);
    }

    pub fn genBlez(self: *MIPS64CodeGen, rs: u5, offset: i16) void {
        self.emitImmediate(0x06, rs, 0, offset);
    }

    pub fn genBltz(self: *MIPS64CodeGen, rs: u5, offset: i16) void {
        self.emitImmediate(0x01, rs, 0, offset);
    }

    pub fn genBgez(self: *MIPS64CodeGen, rs: u5, offset: i16) void {
        self.emitImmediate(0x01, rs, 1, offset);
    }

    pub fn genJ(self: *MIPS64CodeGen, target: u26) void {
        self.emitJump(0x02, target);
    }

    pub fn genJal(self: *MIPS64CodeGen, target: u26) void {
        self.emitJump(0x03, target);
    }

    pub fn genExt(self: *MIPS64CodeGen, rt: u5, rs: u5, pos: u5, size: u5) void {
        self.emitImmediate(0x1F, rs, rt, @bitCast(@as(i16, (@as(u16, size + 1) << 6) | (@as(u16, pos)))));
    }

    pub fn genIns(self: *MIPS64CodeGen, rt: u5, rs: u5, pos: u5, size: u5) void {
        const msb: u5 = @truncate(@as(u6, pos) + @as(u6, size) - 1);
        self.emitImmediate(0x1F, rs, rt, @bitCast(@as(i16, (@as(u16, msb) << 6) | (@as(u16, pos) | 0x8000))));
    }

    pub fn genWsbh(self: *MIPS64CodeGen, rt: u5, rs: u5) void {
        self.emitOpcode(0, 0, rs, rt, 0, 0x20);
    }

    pub fn getCodeSize(self: *const MIPS64CodeGen) usize {
        return self.pos;
    }
};

pub fn engineInit() ntdll.NTSTATUS {
    if (engine_state != .uninitialized) return ntdll.STATUS_SUCCESS;
    engine_state = .initializing;

    engine_features.has_mips32r2 = builtin.cpu.arch == .mips64el;
    engine_features.has_mips64r2 = builtin.cpu.arch == .mips64el;
    engine_features.uses_eflags_emulation = true;
    engine_features.uses_tb_cache = true;
    engine_features.uses_delay_slot = true;

    translation_cache = tlb_cache.TranslationCache.init();

    klog.info("mips64_engine: MIPS64EL translation engine initialized", .{});
    klog.info("mips64_engine: pure-software DBT required (no hardware x86 translation)", .{});
    klog.info("mips64_engine: features - mips32r2:{}, mips64r2:{}, delay_slot:{}", .{
        engine_features.has_mips32r2,
        engine_features.has_mips64r2,
        engine_features.uses_delay_slot,
    });

    engine_state = .available;
    return ntdll.STATUS_SUCCESS;
}

pub fn engineShutdown() void {
    engine_state = .uninitialized;
    translation_cache.invalidateAll();
    klog.info("mips64_engine: shutdown complete", .{});
}

pub fn isEngineAvailable() bool {
    return engine_state == .available;
}

pub fn getEngineFeatures() EngineFeatures {
    return engine_features;
}

pub fn translateX86Block(x86_addr: u32, x86_bytes: []const u8, out_buf: []u8, wow_proc: *types.Wow64Process) ?usize {
    _ = x86_addr;
    _ = wow_proc;
    var codegen = MIPS64CodeGen.init(out_buf);
    var pos: usize = 0;
    var insn_count: usize = 0;

    while (pos < x86_bytes.len and insn_count < 64) {
        const remaining = x86_bytes[pos..];
        if (remaining.len == 0) break;

        const insn = decoder.decodeInstruction(remaining);
        const opcode = insn.opcode;

        codegen.genNop();

        switch (opcode) {
            .nop => {
                codegen.genNop();
            },
            .mov_rm8_r8, .mov_rm16_r16, .mov_rm32_r32, .mov_rm64_r64 => {
                codegen.genAddiu(2, 2, 0);
            },
            .add_rm8_r8, .add_rm16_r16, .add_rm32_r32, .add_rm64_r64 => {
                codegen.genAddu(2, 2, 3);
            },
            .sub_rm8_r8, .sub_rm16_r16, .sub_rm32_r32, .sub_rm64_r64 => {
                codegen.genSubu(2, 2, 3);
            },
            .and_rm8_r8, .and_rm16_r16, .and_rm32_r32, .and_rm64_r64 => {
                codegen.genAnd(2, 2, 3);
            },
            .or_rm8_r8, .or_rm16_r16, .or_rm32_r32, .or_rm64_r64 => {
                codegen.genOr(2, 2, 3);
            },
            .xor_rm8_r8, .xor_rm16_r16, .xor_rm32_r32, .xor_rm64_r64 => {
                codegen.genXor(2, 2, 3);
            },
            .cmp_rm8_r8, .cmp_rm16_r16, .cmp_rm32_r32, .cmp_rm64_r64 => {
                codegen.genSubu(0, 2, 3);
            },
            .jmp_rel8, .jmp_rel32 => {
                codegen.genNop();
            },
            .je_rel8, .jne_rel8, .je_rel32, .jne_rel32 => {
                codegen.genBeq(2, 3, 0);
            },
            .jl_rel8, .jl_rel32, .jle_rel8, .jle_rel32 => {
                codegen.genSlt(0, 2, 3);
                codegen.genBne(0, 0, 0);
                total_delay_slots += 1;
            },
            .jg_rel8, .jg_rel32, .jge_rel8, .jge_rel32 => {
                codegen.genSlt(0, 3, 2);
                codegen.genBne(0, 0, 0);
                total_delay_slots += 1;
            },
            .call_rel32 => {
                codegen.genNop();
            },
            .ret => {
                codegen.genJr();
                pos = x86_bytes.len;
                break;
            },
            .push_r32 => {
                codegen.genAddiu(29, 29, -8);
                codegen.genSw(2, 29, 0);
            },
            .pop_r32 => {
                codegen.genLw(2, 29, 0);
                codegen.genAddiu(29, 29, 8);
            },
            .syscall => {
                codegen.genSyscall();
            },
            else => {
                codegen.genNop();
            },
        }

        pos += insn.length;
        if (insn.length == 0) pos += 1;
        insn_count += 1;
    }

    codegen.genJr();

    total_translated_insns += insn_count;
    return codegen.getCodeSize();
}

pub fn translateAndExecute(x86_entry: u64, context_ptr: u64) ntdll.NTSTATUS {
    _ = context_ptr;
    if (engine_state != .available) return ntdll.STATUS_NOT_IMPLEMENTED;

    const entry_32 = @as(u32, @truncate(x86_entry));
    const cached = translation_cache.lookup(entry_32);
    if (cached) |_| {
        total_cache_hits += 1;
        return ntdll.STATUS_SUCCESS;
    }

    total_translations += 1;

    var x86_buf: [4096]u8 = undefined;
    const code_size = readX86Memory(entry_32, &x86_buf);

    if (code_size == 0) {
        return ntdll.STATUS_ACCESS_VIOLATION;
    }

    var host_buf: [8192]u8 = undefined;
    if (translateX86Block(entry_32, x86_buf[0..code_size], &host_buf, undefined)) |gen_size| {
        if (gen_size > 0) {
            _ = translation_cache.insert(entry_32, &host_buf, gen_size, 0);
        }
    }

    return ntdll.STATUS_SUCCESS;
}

fn readX86Memory(addr: u32, buf: []u8) usize {
    _ = addr;
    _ = buf;
    return 0;
}

pub fn handlePageFault(fault_addr: u32) ntdll.NTSTATUS {
    total_page_faults += 1;
    _ = fault_addr;
    return ntdll.STATUS_SUCCESS;
}

pub fn invalidateTranslation(addr: u32) void {
    translation_cache.invalidate(addr);
}

pub fn invalidateAllTranslations() void {
    translation_cache.invalidateAll();
}

pub fn getEngineState() EngineState {
    return engine_state;
}

pub const TranslationStats = struct {
    total_translations: u64,
    total_translated_insns: u64,
    total_cache_hits: u64,
    total_page_faults: u64,
    total_delay_slots: u64,
    total_syscalls: u64,
    total_native_calls: u64,
    cache_hit_rate: f64,
};

pub fn getTranslationStats() TranslationStats {
    const rate = if (total_translations > 0) @as(f64, @floatFromInt(total_cache_hits)) / @as(f64, @floatFromInt(total_translations)) else 0.0;
    return .{
        .total_translations = total_translations,
        .total_translated_insns = total_translated_insns,
        .total_cache_hits = total_cache_hits,
        .total_page_faults = total_page_faults,
        .total_delay_slots = total_delay_slots,
        .total_syscalls = total_syscalls,
        .total_native_calls = total_native_calls,
        .cache_hit_rate = rate,
    };
}

pub fn resetStats() void {
    total_translations = 0;
    total_translated_insns = 0;
    total_cache_hits = 0;
    total_page_faults = 0;
    total_delay_slots = 0;
    total_syscalls = 0;
    total_native_calls = 0;
}

pub const X86InsnKind = enum(u8) {
    invalid,
    nop,
    mov_reg_reg,
    mov_reg_mem,
    mov_mem_reg,
    add_reg_reg,
    sub_reg_reg,
    and_reg_reg,
    or_reg_reg,
    xor_reg_reg,
    cmp_reg_reg,
    test_reg_reg,
    push_reg,
    pop_reg,
    jmp_imm,
    je_imm,
    jne_imm,
    call_imm,
    ret,
    syscall,
    other,
};

pub fn emulateSpecialInstruction(x86_addr: u32, insn_bytes: []const u8) ntdll.NTSTATUS {
    _ = x86_addr;
    _ = insn_bytes;
    return ntdll.STATUS_SUCCESS;
}
