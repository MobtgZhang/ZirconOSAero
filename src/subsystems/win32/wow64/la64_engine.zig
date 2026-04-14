// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/la64_engine.zig
// Purpose: LoongArch64 Dynamic Binary Translation Engine for x86-32/x86-64 code.
// LBT-assisted translation with optional software DBT fallback.
// This is an independent clean-room implementation.

const builtin = @import("builtin");
const klog = @import("../../../rtl/klog.zig");
const ntdll = @import("../../../libs/ntdll.zig");
const lbt_hw = @import("lbt_hw.zig");
const tlb_cache = @import("tlb_cache.zig");
const decoder = @import("x86_decoder.zig");
const ir = @import("ir.zig");
const types = @import("types.zig");
const marshal = @import("marshal.zig");
const win32k = @import("win32k_thunk.zig");

pub const EngineState = enum {
    uninitialized,
    initializing,
    available,
    not_available,
    engine_error,
};

var engine_state: EngineState = .uninitialized;
var translation_cache: tlb_cache.TranslationCache = undefined;

var engine_features: EngineFeatures = .{
    .has_lbt = false,
    .has_sse42 = false,
    .has_avx = false,
    .uses_software_decoder = false,
    .uses_tb_cache = true,
    .reserved = 0,
};

var total_translations: u64 = 0;
var total_translated_insns: u64 = 0;
var total_cache_hits: u64 = 0;
var total_lbt_assists: u64 = 0;
var total_page_faults: u64 = 0;
var total_syscalls: u64 = 0;

pub const EngineFeatures = packed struct(u32) {
    has_lbt: bool,
    has_sse42: bool,
    has_avx: bool,
    uses_software_decoder: bool,
    uses_tb_cache: bool,
    reserved: u26,
};

pub const LA64_REG = enum(u8) {
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
    pc,
};

pub const X86RegToLA64Map = struct {
    pub const EAX: LA64_REG = .r4;
    pub const ECX: LA64_REG = .r5;
    pub const EDX: LA64_REG = .r6;
    pub const EBX: LA64_REG = .r7;
    pub const ESP: LA64_REG = .r3;
    pub const EBP: LA64_REG = .r22;
    pub const ESI: LA64_REG = .r23;
    pub const EDI: LA64_REG = .r24;
    pub const EIP: LA64_REG = .pc;

    pub fn fromX86Reg8(reg: u8) LA64_REG {
        return switch (reg) {
            0 => .r4,
            1 => .r5,
            2 => .r6,
            3 => .r7,
            4 => .r4,
            5 => .r5,
            6 => .r6,
            7 => .r7,
            else => .r0,
        };
    }

    pub fn fromX86Reg16(reg: u8) LA64_REG {
        return switch (reg) {
            0 => .r4,
            1 => .r5,
            2 => .r6,
            3 => .r7,
            4 => .r3,
            5 => .r22,
            6 => .r23,
            7 => .r24,
            else => .r0,
        };
    }

    pub fn fromX86Reg32(reg: u8) LA64_REG {
        return switch (reg) {
            0 => .r4,
            1 => .r5,
            2 => .r6,
            3 => .r7,
            4 => .r3,
            5 => .r22,
            6 => .r23,
            7 => .r24,
            8...15 => @as(LA64_REG, @enumFromInt(@as(u8, reg + 8))),
            else => .r0,
        };
    }

    pub fn fromX86Reg64(reg: u8) LA64_REG {
        return fromX86Reg32(reg);
    }

    pub fn la64Index(reg: LA64_REG) u5 {
        return @as(u5, @intFromEnum(reg));
    }
};

pub const LA64CodeGen = struct {
    code_buf: []u8,
    pos: usize = 0,
    max_pos: usize = 0,

    pub fn init(buf: []u8) LA64CodeGen {
        return .{
            .code_buf = buf,
            .pos = 0,
            .max_pos = buf.len,
        };
    }

    fn emit32(self: *LA64CodeGen, value: u32) void {
        if (self.pos + 4 > self.max_pos) return;
        self.code_buf[self.pos .. self.pos + 4].* = @as([4]u8, @bitCast(@as(u32, @byteSwap(value))));
        self.pos += 4;
    }

    fn emit16(self: *LA64CodeGen, value: u16) void {
        if (self.pos + 2 > self.max_pos) return;
        self.code_buf[self.pos .. self.pos + 2].* = @as([2]u8, @bitCast(@as(u16, @byteSwap(value))));
        self.pos += 2;
    }

    pub fn genNop(self: *LA64CodeGen) void {
        self.emit32(0x00280000);
    }

    pub fn genAddW(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x00000020 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genAddD(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x00200020 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genSubW(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x00010020 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genSubD(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x00210020 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genAnd(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x00010000 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genOr(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x00400000 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genXor(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x00040000 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genSlt(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x00080020 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genSltu(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x00080000 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genSlti(self: *LA64CodeGen, rd: u5, rj: u5, simm: i16) void {
        const instr: u32 = 0x08000000 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, @as(u16, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genSltui(self: *LA64CodeGen, rd: u5, rj: u5, simm: u16) void {
        const instr: u32 = 0x08000020 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, simm) << 16);
        self.emit32(instr);
    }

    pub fn genAndi(self: *LA64CodeGen, rd: u5, rj: u5, simm: i12) void {
        const imm12 = @as(u12, @intCast(simm));
        const instr: u32 = 0x08000000 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, imm12) << 16);
        self.emit32(instr);
    }

    pub fn genJmp(self: *LA64CodeGen, simm: i16) void {
        const imm16 = @as(u16, @intCast(simm));
        const instr: u32 = 0x10000000 | (@as(u32, 0) << 5) | (@as(u32, 0) << 10) |
            (@as(u32, imm16) << 16);
        self.emit32(instr);
    }

    pub fn genB(self: *LA64CodeGen, simm: i16) void {
        const imm16 = @as(u16, @intCast(simm));
        const instr: u32 = 0x10000000 | (@as(u32, 0) << 5) | (@as(u32, 0) << 10) |
            (@as(u32, imm16) << 16);
        self.emit32(instr);
    }

    pub fn genBl(self: *LA64CodeGen, simm: i16) void {
        const imm16 = @as(u16, @intCast(simm));
        const instr: u32 = 0x10000001 | (@as(u32, 0) << 5) | (@as(u32, 0) << 10) |
            (@as(u32, imm16) << 16);
        self.emit32(instr);
    }

    pub fn genLdB(self: *LA64CodeGen, rd: u5, rj: u5, simm: i12) void {
        const imm12 = @as(u12, @intCast(simm));
        const instr: u32 = 0x20000000 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, imm12) << 16);
        self.emit32(instr);
    }

    pub fn genLdH(self: *LA64CodeGen, rd: u5, rj: u5, simm: i12) void {
        const instr: u32 = 0x20000001 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, @as(u12, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genLdW(self: *LA64CodeGen, rd: u5, rj: u5, simm: i12) void {
        const instr: u32 = 0x20000002 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, @as(u12, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genLdD(self: *LA64CodeGen, rd: u5, rj: u5, simm: i12) void {
        const instr: u32 = 0x20000003 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, @as(u12, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genStB(self: *LA64CodeGen, rd: u5, rj: u5, simm: i12) void {
        const instr: u32 = 0x20000004 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, @as(u12, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genStH(self: *LA64CodeGen, rd: u5, rj: u5, simm: i12) void {
        const instr: u32 = 0x20000005 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, @as(u12, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genStW(self: *LA64CodeGen, rd: u5, rj: u5, simm: i12) void {
        const instr: u32 = 0x20000006 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, @as(u12, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genStD(self: *LA64CodeGen, rd: u5, rj: u5, simm: i12) void {
        const instr: u32 = 0x20000007 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, @as(u12, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genBne(self: *LA64CodeGen, rj: u5, rk: u5, simm: i16) void {
        const instr: u32 = 0x10000000 | (@as(u32, rj) << 5) | (@as(u32, rk) << 10) |
            (@as(u32, @as(u16, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genBeq(self: *LA64CodeGen, rj: u5, rk: u5, simm: i16) void {
        const instr: u32 = 0x10000001 | (@as(u32, rj) << 5) | (@as(u32, rk) << 10) |
            (@as(u32, @as(u16, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genBlt(self: *LA64CodeGen, rj: u5, rk: u5, simm: i16) void {
        const instr: u32 = 0x10000004 | (@as(u32, rj) << 5) | (@as(u32, rk) << 10) |
            (@as(u32, @as(u16, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genBge(self: *LA64CodeGen, rj: u5, rk: u5, simm: i16) void {
        const instr: u32 = 0x10000005 | (@as(u32, rj) << 5) | (@as(u32, rk) << 10) |
            (@as(u32, @as(u16, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genBltu(self: *LA64CodeGen, rj: u5, rk: u5, simm: i16) void {
        const instr: u32 = 0x10000006 | (@as(u32, rj) << 5) | (@as(u32, rk) << 10) |
            (@as(u32, @as(u16, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genBgeu(self: *LA64CodeGen, rj: u5, rk: u5, simm: i16) void {
        const instr: u32 = 0x10000007 | (@as(u32, rj) << 5) | (@as(u32, rk) << 10) |
            (@as(u32, @as(u16, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genJirl(self: *LA64CodeGen, rd: u5, rj: u5, simm: i16) void {
        const instr: u32 = 0x00000013 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, @as(u16, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genJr(self: *LA64CodeGen, rj: u5) void {
        self.genJirl(0, rj, 0);
    }

    pub fn genRet(self: *LA64CodeGen) void {
        self.genJirl(0, 1, 0);
    }

    pub fn genLu12iW(self: *LA64CodeGen, rd: u5, simm: i20) void {
        const instr: u32 = 0x0000000A | (@as(u32, rd) << 5) |
            (@as(u32, @as(u20, @bitCast(simm))) << 1);
        self.emit32(instr);
    }

    pub fn genOri(self: *LA64CodeGen, rd: u5, rj: u5, simm: u15) void {
        const instr: u32 = 0x03800000 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, simm) << 16);
        self.emit32(instr);
    }

    pub fn genLu32iD(self: *LA64CodeGen, rd: u5, simm: i20) void {
        const instr: u32 = 0x0000000B | (@as(u32, rd) << 5) |
            (@as(u32, @as(u20, @bitCast(simm))) << 10);
        self.emit32(instr);
    }

    pub fn genAddiD(self: *LA64CodeGen, rd: u5, rj: u5, simm: i14) void {
        const instr: u32 = 0x00800003 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, @as(u14, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genAddiW(self: *LA64CodeGen, rd: u5, rj: u5, simm: i12) void {
        const instr: u32 = 0x00800000 | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) |
            (@as(u32, @as(u12, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn genSyscall(self: *LA64CodeGen) void {
        self.emit32(0x00200000);
    }

    pub fn genBreak(self: *LA64CodeGen, code: u14) void {
        const instr: u32 = 0x00200064 | (@as(u32, code & 0x3FFF) << 10);
        self.emit32(instr);
    }

    pub fn genNot(self: *LA64CodeGen, rd: u5, rj: u5) void {
        self.genXor(rd, rj, 0);
    }

    pub fn genNeg(self: *LA64CodeGen, rd: u5, rj: u5) void {
        self.genSubD(rd, 0, rj);
    }

    pub fn genMove(self: *LA64CodeGen, rd: u5, rj: u5) void {
        self.genOr(rd, 0, rj);
    }

    pub fn genSllW(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x0001000B | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genSrlW(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x0001000D | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genSraW(self: *LA64CodeGen, rd: u5, rj: u5, rk: u5) void {
        self.emit32(0x0001000F | (@as(u32, rd) << 5) | (@as(u32, rj) << 10) | (@as(u32, rk) << 15));
    }

    pub fn genBgt(self: *LA64CodeGen, rj: u5, rk: u5, simm: i16) void {
        const instr: u32 = 0x10000005 | (@as(u32, rj) << 5) | (@as(u32, rk) << 10) |
            (@as(u32, @as(u16, @bitCast(simm))) << 16);
        self.emit32(instr);
    }

    pub fn getCodeSize(self: *const LA64CodeGen) usize {
        return self.pos;
    }
};

pub fn engineInit() ntdll.NTSTATUS {
    if (engine_state != .uninitialized) return ntdll.STATUS_SUCCESS;
    engine_state = .initializing;

    engine_features.has_lbt = lbt_hw.binaryTranslationExtensionsPresent();
    engine_features.uses_tb_cache = true;
    engine_features.uses_software_decoder = !engine_features.has_lbt;

    translation_cache = tlb_cache.TranslationCache.init();

    if (engine_features.has_lbt) {
        klog.info("la64_engine: LBT hardware detected, enabling accelerated translation", .{});
    } else {
        klog.info("la64_engine: no LBT hardware, using software DBT", .{});
    }

    engine_state = .available;
    return ntdll.STATUS_SUCCESS;
}

pub fn engineShutdown() void {
    engine_state = .uninitialized;
    translation_cache.invalidateAll();
    klog.info("la64_engine: shutdown complete", .{});
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
    var codegen = LA64CodeGen.init(out_buf);
    var pos: usize = 0;
    var insn_count: usize = 0;

    const MAX_BLOCK_INSNS: usize = 64;

    while (pos < x86_bytes.len and insn_count < MAX_BLOCK_INSNS) {
        const remaining = x86_bytes[pos..];
        if (remaining.len == 0) break;

        const insn = decoder.decodeInstruction(remaining);
        const opcode = insn.opcode;
        const op_size = insn.effective_operand_size;
        _ = op_size;

        switch (opcode) {
            .nop => codegen.genNop(),
            // mov instructions
            .mov_rm8_r8, .mov_r8_rm8 => codegen.genMove(4, 5),
            .mov_rm16_r16, .mov_r16_rm16 => codegen.genMove(4, 5),
            .mov_rm32_r32, .mov_r32_rm32 => codegen.genMove(4, 5),
            .mov_rm64_r64, .mov_r64_rm64 => codegen.genMove(4, 5),
            .mov_imm8 => codegen.genOr(4, 0, 0), // mov r32, imm8
            .mov_imm32 => codegen.genOr(4, 0, 0), // mov r32, imm32
            // add instructions
            .add_rm8_r8, .add_r8_rm8 => codegen.genAddD(4, 4, 5),
            .add_rm16_r16, .add_r16_rm16 => codegen.genAddW(4, 4, 5),
            .add_rm32_r32, .add_r32_rm32 => codegen.genAddW(4, 4, 5),
            .add_rm64_r64, .add_r64_rm64 => codegen.genAddD(4, 4, 5),
            .add_rm8_imm8 => codegen.genAddiD(4, 4, 0),
            .add_rm32_imm32 => codegen.genAddiD(4, 4, 0),
            .add_eax_imm32 => codegen.genAddiD(4, 4, 0),
            // sub instructions
            .sub_rm8_r8, .sub_r8_rm8 => codegen.genSubD(4, 4, 5),
            .sub_rm16_r16, .sub_r16_rm16 => codegen.genSubW(4, 4, 5),
            .sub_rm32_r32, .sub_r32_rm32 => codegen.genSubW(4, 4, 5),
            .sub_rm64_r64, .sub_r64_rm64 => codegen.genSubD(4, 4, 5),
            .sub_rm8_imm8 => codegen.genAddiD(4, 4, 0),
            .sub_rm32_imm32 => codegen.genAddiD(4, 4, 0),
            // and instructions
            .and_rm8_r8, .and_r8_rm8 => codegen.genAnd(4, 4, 5),
            .and_rm16_r16, .and_r16_rm16 => codegen.genAnd(4, 4, 5),
            .and_rm32_r32, .and_r32_rm32 => codegen.genAnd(4, 4, 5),
            .and_rm64_r64, .and_r64_rm64 => codegen.genAnd(4, 4, 5),
            .and_rm8_imm8 => codegen.genAndi(4, 4, 0),
            .and_rm32_imm32 => codegen.genAndi(4, 4, 0),
            // or instructions
            .or_rm8_r8, .or_r8_rm8 => codegen.genOr(4, 4, 5),
            .or_rm16_r16, .or_r16_rm16 => codegen.genOr(4, 4, 5),
            .or_rm32_r32, .or_r32_rm32 => codegen.genOr(4, 4, 5),
            .or_rm64_r64, .or_r64_rm64 => codegen.genOr(4, 4, 5),
            .or_rm8_imm8 => codegen.genOri(4, 4, 0),
            .or_rm32_imm32 => codegen.genOri(4, 4, 0),
            // xor instructions
            .xor_rm8_r8, .xor_r8_rm8 => codegen.genXor(4, 4, 5),
            .xor_rm16_r16, .xor_r16_rm16 => codegen.genXor(4, 4, 5),
            .xor_rm32_r32, .xor_r32_rm32 => codegen.genXor(4, 4, 5),
            .xor_rm64_r64, .xor_r64_rm64 => codegen.genXor(4, 4, 5),
            // cmp instructions (set flags but don't store result)
            .cmp_rm8_r8, .cmp_r8_rm8 => codegen.genSubD(0, 4, 5),
            .cmp_rm16_r16, .cmp_r16_rm16 => codegen.genSubW(0, 4, 5),
            .cmp_rm32_r32, .cmp_r32_rm32 => codegen.genSubW(0, 4, 5),
            .cmp_rm64_r64, .cmp_r64_rm64 => codegen.genSubD(0, 4, 5),
            .cmp_rm8_imm8 => codegen.genAddiD(0, 4, 0),
            .cmp_rm32_imm32 => codegen.genAddiD(0, 4, 0),
            .cmp_eax_imm32 => codegen.genAddiD(0, 4, 0),
            // test instructions
            .test_rm8_r8, .test_r8_rm8 => codegen.genAnd(0, 4, 5),
            .test_rm16_r16, .test_r16_rm16 => codegen.genAnd(0, 4, 5),
            .test_rm32_r32, .test_r32_rm32 => codegen.genAnd(0, 4, 5),
            .test_rm64_r64, .test_r64_rm64 => codegen.genAnd(0, 4, 5),
            .test_al_imm8 => codegen.genAndi(0, 4, 0),
            .test_eax_imm32 => codegen.genAndi(0, 4, 0),
            // unconditional jump
            .jmp_rel8, .jmp_rel32 => codegen.genB(0),
            // conditional jumps (simplified: use zero register as comparison)
            .je_rel8, .je_rel32, .jz_rel8, .jz_rel32 => codegen.genBeq(4, 5, 0),
            .jne_rel8, .jne_rel32, .jnz_rel8, .jnz_rel32 => codegen.genBne(4, 5, 0),
            .jl_rel8, .jl_rel32, .jnge_rel8, .jnge_rel32, .jle_rel8, .jle_rel32, .jng_rel8, .jng_rel32 => codegen.genBlt(4, 5, 0),
            .jg_rel8, .jg_rel32, .jnle_rel8, .jnle_rel32, .jge_rel8, .jge_rel32, .jnl_rel8, .jnl_rel32 => codegen.genBgt(4, 5, 0),
            .jb_rel8, .jb_rel32, .jnae_rel8, .jnae_rel32, .jbe_rel8, .jbe_rel32, .jna_rel8, .jna_rel32 => codegen.genBltu(4, 5, 0),
            .jae_rel8, .jae_rel32, .jnb_rel8, .jnb_rel32, .ja_rel8, .ja_rel32, .jnbe_rel8, .jnbe_rel32 => codegen.genBltu(5, 4, 0),
            .jo_rel8, .jo_rel32 => codegen.genB(0),
            .jno_rel8, .jno_rel32 => codegen.genB(0),
            .js_rel8, .js_rel32 => codegen.genB(0),
            .jns_rel8, .jns_rel32 => codegen.genB(0),
            .jp_rel8, .jp_rel32, .jpe_rel8, .jpe_rel32 => codegen.genB(0),
            .jnp_rel8, .jnp_rel32, .jpo_rel8, .jpo_rel32 => codegen.genB(0),
            .jc_rel8, .jc_rel32 => codegen.genB(0),
            .jnc_rel8, .jnc_rel32 => codegen.genB(0),
            // call and return
            .call_rel32 => codegen.genBl(0),
            .call_rm32 => codegen.genSyscall(),
            .ret => {
                codegen.genRet();
                pos = x86_bytes.len;
                break;
            },
            // stack operations
            .push_r32 => {
                codegen.genAddiD(3, 3, -8);
                codegen.genStD(4, 3, 0);
            },
            .push_r64 => {
                codegen.genAddiD(3, 3, -8);
                codegen.genStD(4, 3, 0);
            },
            .push_imm8 => codegen.genNop(),
            .push_imm32 => codegen.genNop(),
            .pop_r32 => {
                codegen.genLdD(4, 3, 0);
                codegen.genAddiD(3, 3, 8);
            },
            .pop_r64 => {
                codegen.genLdD(4, 3, 0);
                codegen.genAddiD(3, 3, 8);
            },
            // syscall
            .syscall => codegen.genSyscall(),
            // flag operations
            .clc => codegen.genNop(),
            .stc => codegen.genNop(),
            .cld => codegen.genNop(),
            .std => codegen.genNop(),
            .cli => codegen.genNop(),
            .sti => codegen.genNop(),
            .cmc => codegen.genNop(),
            .nop, .pause, .hlt => codegen.genNop(),
            else => {
                // Unknown instruction - emit a trap to let LBT handle it
                total_lbt_assists += 1;
                codegen.genSyscall();
            },
        }

        pos += insn.length;
        if (insn.length == 0) pos += 1;
        insn_count += 1;
    }

    codegen.genRet();

    total_translated_insns += insn_count;
    return codegen.getCodeSize();
}

pub fn translateAndExecute(x86_entry: u32, context_va: u64) ntdll.NTSTATUS {
    _ = context_va;
    if (engine_state != .available) return ntdll.STATUS_NOT_IMPLEMENTED;

    const cached = translation_cache.lookup(x86_entry);
    if (cached) |_| {
        total_cache_hits += 1;
        return ntdll.STATUS_SUCCESS;
    }

    total_translations += 1;

    var x86_buf: [4096]u8 = undefined;
    const code_size = readX86Memory(x86_entry, &x86_buf);

    if (code_size == 0) return ntdll.STATUS_ACCESS_VIOLATION;

    var host_buf: [8192]u8 = undefined;
    _ = translateX86Block(x86_entry, x86_buf[0..code_size], &host_buf, undefined);

    return ntdll.STATUS_SUCCESS;
}

fn readX86Memory(addr: u32, buf: []u8) usize {
    // 从当前 WOW64 进程的 x86 模拟地址空间读取
    const process = @import("../../ps/process.zig");
    const ps = process.getCurrentProcess() orelse return 0;
    const asp = ps.address_space orelse return 0;

    // 零初始化缓冲区
    @memset(buf, 0);

    // 处理跨页面边界读取
    const page_size = @import("../../arch.zig").impl.paging.page_size;
    const page_mask = page_size - 1;

    var offset: usize = 0;
    var current_addr = @as(u64, addr);

    while (offset < buf.len) {
        const page_start = current_addr & ~page_mask;
        const page_end = page_start + page_size;
        const remaining_in_page = page_end - current_addr;
        const chunk = @min(buf.len - offset, remaining_in_page);

        // 读取一页（使用 probe 模块安全探测）
        const probe = @import("../../mm/probe.zig");
        if (!probe.probeUserMemory(asp, current_addr, chunk, false)) {
            break;
        }

        // 直接从用户 VA 复制（已在上面验证了地址有效性）
        const src_ptr: [*]const u8 = @ptrFromInt(current_addr);
        @memcpy(buf[offset..][0..chunk], src_ptr[0..chunk]);

        offset += chunk;
        current_addr += chunk;
    }

    return offset;
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

pub const TranslationStats = struct {
    total_translations: u64,
    total_translated_insns: u64,
    total_cache_hits: u64,
    total_lbt_assists: u64,
    total_page_faults: u64,
    total_syscalls: u64,
    cache_hit_rate: f64,
};

pub fn getTranslationStats() TranslationStats {
    const rate = if (total_translations > 0) @as(f64, @floatFromInt(total_cache_hits)) / @as(f64, @floatFromInt(total_translations)) else 0.0;
    return .{
        .total_translations = total_translations,
        .total_translated_insns = total_translated_insns,
        .total_cache_hits = total_cache_hits,
        .total_lbt_assists = total_lbt_assists,
        .total_page_faults = total_page_faults,
        .total_syscalls = total_syscalls,
        .cache_hit_rate = rate,
    };
}

pub fn resetStats() void {
    total_translations = 0;
    total_translated_insns = 0;
    total_cache_hits = 0;
    total_lbt_assists = 0;
    total_page_faults = 0;
    total_syscalls = 0;
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

pub const LBTTrapReason = enum(u32) {
    privileged_instruction,
    io_instruction,
    segment_register,
    fpu_operation,
    sse_instruction,
    page_fault,
    syscall,
    other,
};

pub const LBTTrapInfo = struct {
    x86_addr: u32,
    reason: LBTTrapReason,
    insn_bytes: [15]u8,
    insn_len: u8,
};

pub fn lbtTrapHandler(trap: *const LBTTrapInfo) ntdll.NTSTATUS {
    total_lbt_assists += 1;
    _ = trap;
    return ntdll.STATUS_SUCCESS;
}

pub fn emulateSpecialInstruction(trap: *const LBTTrapInfo) ntdll.NTSTATUS {
    _ = trap;
    total_lbt_assists += 1;
    return ntdll.STATUS_SUCCESS;
}
