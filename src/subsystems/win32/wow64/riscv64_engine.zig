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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/riscv64_engine.zig
// Purpose: RISC-V64 Dynamic Binary Translation Engine for x86-32/x86-64 code.
// This is an independent clean-room implementation.

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
    has_rva: bool,
    has_rvb: bool,
    has_rvv: bool,
    uses_software_decoder: bool,
    uses_tb_cache: bool,
    uses_eflags_emulation: bool,
    reserved: u25,
};

var engine_features: EngineFeatures = .{
    .has_rva = false,
    .has_rvb = false,
    .has_rvv = false,
    .uses_software_decoder = true,
    .uses_tb_cache = true,
    .uses_eflags_emulation = true,
    .reserved = 0,
};

var total_translations: u64 = 0;
var total_translated_insns: u64 = 0;
var total_cache_hits: u64 = 0;
var total_page_faults: u64 = 0;
var total_syscalls: u64 = 0;

pub const RV64_REG = enum(u8) {
    zero,
    ra,
    sp,
    gp,
    tp,
    t0,
    t1,
    t2,
    s0,
    s1,
    a0,
    a1,
    a2,
    a3,
    a4,
    a5,
    a6,
    a7,
    s2,
    s3,
    s4,
    s5,
    s6,
    s7,
    s8,
    s9,
    s10,
    s11,
    t3,
    t4,
    t5,
    t6,
};

pub const X86RegToRV64Map = struct {
    pub const EAX: RV64_REG = .a0;
    pub const ECX: RV64_REG = .a1;
    pub const EDX: RV64_REG = .a2;
    pub const EBX: RV64_REG = .s0;
    pub const ESP: RV64_REG = .sp;
    pub const EBP: RV64_REG = .s1;
    pub const ESI: RV64_REG = .s2;
    pub const EDI: RV64_REG = .s3;

    pub fn fromX86Reg8(reg: u8) RV64_REG {
        return switch (reg) {
            0 => .a0,
            1 => .a1,
            2 => .a2,
            3 => .s0,
            4 => .a0,
            5 => .a1,
            6 => .a2,
            7 => .s0,
            else => .zero,
        };
    }

    pub fn fromX86Reg32(reg: u8) RV64_REG {
        return switch (reg) {
            0 => .a0,
            1 => .a1,
            2 => .a2,
            3 => .s0,
            4 => .sp,
            5 => .s1,
            6 => .s2,
            7 => .s3,
            else => .zero,
        };
    }
};

pub const RV64CodeGen = struct {
    code_buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) RV64CodeGen {
        return .{
            .code_buf = buf,
            .pos = 0,
        };
    }

    fn emit32(self: *RV64CodeGen, value: u32) void {
        if (self.pos + 4 <= self.code_buf.len) {
            self.code_buf[self.pos .. self.pos + 4].* = @as([4]u8, @bitCast(value));
            self.pos += 4;
        }
    }

    fn emitR(self: *RV64CodeGen, opcode: u7, rd: u5, funct3: u3, rs1: u5, rs2: u5, funct7: u7) void {
        const instr: u32 = (@as(u32, funct7) << 25) | (@as(u32, rs2) << 20) | (@as(u32, rs1) << 15) |
            (@as(u32, funct3) << 12) | (@as(u32, rd) << 7) | opcode;
        self.emit32(instr);
    }

    fn emitI(self: *RV64CodeGen, opcode: u7, rd: u5, funct3: u3, rs1: u5, imm: u12) void {
        const instr: u32 = (@as(u32, @bitCast(@as(i12, @bitCast(imm)))) << 20) |
            (@as(u32, rs1) << 15) | (@as(u32, funct3) << 12) |
            (@as(u32, rd) << 7) | opcode;
        self.emit32(instr);
    }

    fn emitS(self: *RV64CodeGen, opcode: u7, funct3: u3, rs1: u5, rs2: u5, imm: u12) void {
        const imm11_5: u7 = @truncate(imm >> 5);
        const imm4_0: u5 = @truncate(imm);
        const instr: u32 = (@as(u32, imm11_5) << 25) | (@as(u32, rs2) << 20) |
            (@as(u32, rs1) << 15) | (@as(u32, funct3) << 12) |
            (@as(u32, imm4_0) << 7) | opcode;
        self.emit32(instr);
    }

    fn emitB(self: *RV64CodeGen, opcode: u7, funct3: u3, rs1: u5, rs2: u5, imm: u13) void {
        const imm12: u1 = @truncate(imm >> 12);
        const imm10_5: u6 = @truncate(imm >> 5);
        const imm4_1: u4 = @truncate(imm >> 1);
        const imm11: u1 = @truncate(imm >> 11);
        const instr: u32 = (@as(u32, imm12) << 31) | (@as(u32, imm11) << 30) |
            (@as(u32, imm10_5) << 25) | (@as(u32, rs2) << 20) |
            (@as(u32, rs1) << 15) | (@as(u32, funct3) << 12) |
            (@as(u32, imm4_1) << 8) | (@as(u32, imm12) << 7) | opcode;
        self.emit32(instr);
    }

    fn emitU(self: *RV64CodeGen, opcode: u7, rd: u5, imm: u20) void {
        const instr: u32 = (@as(u32, imm) << 12) | (@as(u32, rd) << 7) | opcode;
        self.emit32(instr);
    }

    fn emitJ(self: *RV64CodeGen, opcode: u7, rd: u5, imm: u21) void {
        const imm20: u1 = @truncate(imm >> 20);
        const imm10_1: u10 = @truncate(imm >> 1);
        const imm11: u1 = @truncate(imm >> 11);
        const imm19_12: u8 = @truncate(imm >> 12);
        const instr: u32 = (@as(u32, imm20) << 31) | (@as(u32, imm19_12) << 12) |
            (@as(u32, imm11) << 20) | (@as(u32, imm10_1) << 21) | (@as(u32, rd) << 7) | opcode;
        self.emit32(instr);
    }

    pub fn genAddiw(self: *RV64CodeGen, rd: u5, rs1: u5, imm: i12) void {
        self.emitI(0x1B, rd, 0, rs1, @as(u12, @bitCast(imm)));
    }

    pub fn genAddw(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x3B, rd, 0, rs1, rs2, 0x00);
    }

    pub fn genSubw(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x3B, rd, 0, rs1, rs2, 0x20);
    }

    pub fn genAddi(self: *RV64CodeGen, rd: u5, rs1: u5, imm: i12) void {
        self.emitI(0x13, rd, 0, rs1, @as(u12, @bitCast(imm)));
    }

    pub fn genAdd(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 0, rs1, rs2, 0);
    }

    pub fn genSub(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 0, rs1, rs2, 0x20);
    }

    pub fn genAndi(self: *RV64CodeGen, rd: u5, rs1: u5, imm: u12) void {
        self.emitI(0x13, rd, 7, rs1, imm);
    }

    pub fn genAnd(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 7, rs1, rs2, 0);
    }

    pub fn genOri(self: *RV64CodeGen, rd: u5, rs1: u5, imm: u12) void {
        self.emitI(0x13, rd, 6, rs1, imm);
    }

    pub fn genOr(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 6, rs1, rs2, 0);
    }

    pub fn genXori(self: *RV64CodeGen, rd: u5, rs1: u5, imm: u12) void {
        self.emitI(0x13, rd, 4, rs1, imm);
    }

    pub fn genXor(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 4, rs1, rs2, 0);
    }

    pub fn genSlti(self: *RV64CodeGen, rd: u5, rs1: u5, imm: i12) void {
        self.emitI(0x13, rd, 2, rs1, @as(u12, @bitCast(imm)));
    }

    pub fn genSltiu(self: *RV64CodeGen, rd: u5, rs1: u5, imm: u12) void {
        self.emitI(0x13, rd, 3, rs1, imm);
    }

    pub fn genSlt(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 2, rs1, rs2, 0);
    }

    pub fn genSltu(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 3, rs1, rs2, 0);
    }

    pub fn genSlli(self: *RV64CodeGen, rd: u5, rs1: u5, shamt: u6) void {
        const instr: u32 = (0x01 << 30) | (@as(u32, shamt) << 20) | (@as(u32, rs1) << 15) | (0x01 << 12) | (@as(u32, rd) << 7) | 0x13;
        self.emit32(instr);
    }

    pub fn genSrli(self: *RV64CodeGen, rd: u5, rs1: u5, shamt: u6) void {
        const instr: u32 = (0x00 << 30) | (@as(u32, shamt) << 20) | (@as(u32, rs1) << 15) | (0x05 << 12) | (@as(u32, rd) << 7) | 0x13;
        self.emit32(instr);
    }

    pub fn genSrai(self: *RV64CodeGen, rd: u5, rs1: u5, shamt: u6) void {
        const instr: u32 = (0x20 << 25) | (@as(u32, shamt) << 20) | (@as(u32, rs1) << 15) | (0x05 << 12) | (@as(u32, rd) << 7) | 0x13;
        self.emit32(instr);
    }

    pub fn genLw(self: *RV64CodeGen, rd: u5, rs1: u5, imm: i12) void {
        self.emitI(0x03, rd, 2, rs1, @as(u12, @bitCast(imm)));
    }

    pub fn genLd(self: *RV64CodeGen, rd: u5, rs1: u5, imm: i12) void {
        self.emitI(0x03, rd, 3, rs1, @as(u12, @bitCast(imm)));
    }

    pub fn genLb(self: *RV64CodeGen, rd: u5, rs1: u5, imm: i12) void {
        self.emitI(0x03, rd, 0, rs1, @as(u12, @bitCast(imm)));
    }

    pub fn genLh(self: *RV64CodeGen, rd: u5, rs1: u5, imm: i12) void {
        self.emitI(0x03, rd, 1, rs1, @as(u12, @bitCast(imm)));
    }

    pub fn genSw(self: *RV64CodeGen, rs2: u5, rs1: u5, imm: i12) void {
        self.emitS(0x23, 2, rs1, rs2, @as(u12, @bitCast(imm)));
    }

    pub fn genSd(self: *RV64CodeGen, rs2: u5, rs1: u5, imm: i12) void {
        self.emitS(0x23, 3, rs1, rs2, @as(u12, @bitCast(imm)));
    }

    pub fn genSb(self: *RV64CodeGen, rs2: u5, rs1: u5, imm: i12) void {
        self.emitS(0x23, 0, rs1, rs2, @as(u12, @bitCast(imm)));
    }

    pub fn genSh(self: *RV64CodeGen, rs2: u5, rs1: u5, imm: i12) void {
        self.emitS(0x23, 1, rs1, rs2, @as(u12, @bitCast(imm)));
    }

    pub fn genBeq(self: *RV64CodeGen, rs1: u5, rs2: u5, imm: i13) void {
        self.emitB(0x63, 0, rs1, rs2, @as(u13, @bitCast(imm)));
    }

    pub fn genBne(self: *RV64CodeGen, rs1: u5, rs2: u5, imm: i13) void {
        self.emitB(0x63, 1, rs1, rs2, @as(u13, @bitCast(imm)));
    }

    pub fn genBlt(self: *RV64CodeGen, rs1: u5, rs2: u5, imm: i13) void {
        self.emitB(0x63, 4, rs1, rs2, @as(u13, @bitCast(imm)));
    }

    pub fn genBge(self: *RV64CodeGen, rs1: u5, rs2: u5, imm: i13) void {
        self.emitB(0x63, 5, rs1, rs2, @as(u13, @bitCast(imm)));
    }

    pub fn genBltu(self: *RV64CodeGen, rs1: u5, rs2: u5, imm: i13) void {
        self.emitB(0x63, 6, rs1, rs2, @as(u13, @bitCast(imm)));
    }

    pub fn genBgeu(self: *RV64CodeGen, rs1: u5, rs2: u5, imm: i13) void {
        self.emitB(0x63, 7, rs1, rs2, @as(u13, @bitCast(imm)));
    }

    pub fn genBnez(self: *RV64CodeGen, rs: u5, imm: i13) void {
        self.emitB(0x63, 1, rs, 0, @as(u13, @bitCast(imm)));
    }

    pub fn genBgt(self: *RV64CodeGen, rs1: u5, rs2: u5, imm: i13) void {
        self.emitB(0x63, 4, rs2, rs1, @as(u13, @bitCast(imm)));
    }

    pub fn genBgtu(self: *RV64CodeGen, rs1: u5, rs2: u5, imm: i13) void {
        self.emitB(0x63, 6, rs2, rs1, @as(u13, @bitCast(imm)));
    }

    pub fn genJal(self: *RV64CodeGen, rd: u5, imm: i21) void {
        self.emitJ(0x6F, rd, @as(u21, @bitCast(imm)));
    }

    pub fn genJalr(self: *RV64CodeGen, rd: u5, rs1: u5, imm: i12) void {
        self.emitI(0x67, rd, 0, rs1, @as(u12, @bitCast(imm)));
    }

    pub fn genRet(self: *RV64CodeGen) void {
        self.genJalr(0, 1, 0);
    }

    pub fn genEcall(self: *RV64CodeGen) void {
        self.emit32(0x00000073);
    }

    pub fn genEbreak(self: *RV64CodeGen) void {
        self.emit32(0x00100073);
    }

    pub fn genNop(self: *RV64CodeGen) void {
        self.emit32(0x00000013);
    }

    pub fn genLui(self: *RV64CodeGen, rd: u5, imm: u20) void {
        self.emitU(0x37, rd, imm);
    }

    pub fn genAuipc(self: *RV64CodeGen, rd: u5, imm: u20) void {
        self.emitU(0x17, rd, imm);
    }

    pub fn genSlliw(self: *RV64CodeGen, rd: u5, rs1: u5, shamt: u6) void {
        const instr: u32 = (@as(u32, shamt) << 20) | (@as(u32, rs1) << 15) | (0x01 << 12) | (@as(u32, rd) << 7) | 0x1B;
        self.emit32(instr);
    }

    pub fn genSrliw(self: *RV64CodeGen, rd: u5, rs1: u5, shamt: u6) void {
        const instr: u32 = (@as(u32, shamt) << 20) | (@as(u32, rs1) << 15) | (0x05 << 12) | (@as(u32, rd) << 7) | 0x1B;
        self.emit32(instr);
    }

    pub fn genSraiw(self: *RV64CodeGen, rd: u5, rs1: u5, shamt: u6) void {
        const instr: u32 = (0x20 << 25) | (@as(u32, shamt) << 20) | (@as(u32, rs1) << 15) | (0x05 << 12) | (@as(u32, rd) << 7) | 0x1B;
        self.emit32(instr);
    }

    pub fn genSubiw(self: *RV64CodeGen, rd: u5, rs1: u5, imm: i12) void {
        _ = imm;
        self.emitR(0x3B, rd, 0, rs1, 0, 0x20);
    }

    pub fn genMul(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 0, rs1, rs2, 0x01);
    }

    pub fn genMulh(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 1, rs1, rs2, 0x01);
    }

    pub fn genMulw(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x3B, rd, 0, rs1, rs2, 0x01);
    }

    pub fn genDiv(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 4, rs1, rs2, 0x01);
    }

    pub fn genDivu(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 5, rs1, rs2, 0x01);
    }

    pub fn genDivw(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x3B, rd, 4, rs1, rs2, 0x01);
    }

    pub fn genRem(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 6, rs1, rs2, 0x01);
    }

    pub fn genRemu(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x33, rd, 7, rs1, rs2, 0x01);
    }

    pub fn genRemw(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x3B, rd, 6, rs1, rs2, 0x01);
    }

    pub fn genRemuw(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.emitR(0x3B, rd, 7, rs1, rs2, 0x01);
    }

    pub fn genNeg(self: *RV64CodeGen, rd: u5, rs2: u5) void {
        self.genSub(rd, 0, rs2);
    }

    pub fn genSeqz(self: *RV64CodeGen, rd: u5, rs1: u5) void {
        self.genSltiu(rd, rs1, 1);
    }

    pub fn genSnez(self: *RV64CodeGen, rd: u5, rs1: u5) void {
        self.genSltu(rd, 0, rs1);
    }

    pub fn genSgtz(self: *RV64CodeGen, rd: u5, rs1: u5) void {
        self.genSlt(rd, 0, rs1);
    }

    pub fn genSltz(self: *RV64CodeGen, rd: u5, rs1: u5) void {
        self.genSlt(rd, rs1, 0);
    }

    pub fn genSgt(self: *RV64CodeGen, rd: u5, rs1: u5, rs2: u5) void {
        self.genSlt(rd, rs2, rs1);
    }

    pub fn getCodeSize(self: *const RV64CodeGen) usize {
        return self.pos;
    }
};

pub fn engineInit() ntdll.NTSTATUS {
    if (engine_state != .uninitialized) return ntdll.STATUS_SUCCESS;
    engine_state = .initializing;

    engine_features.has_rva = builtin.cpu.arch == .riscv64;
    engine_features.uses_eflags_emulation = true;
    engine_features.uses_tb_cache = true;

    translation_cache = tlb_cache.TranslationCache.init();

    klog.info("riscv64_engine: RISC-V64 translation engine initialized", .{});
    klog.info("riscv64_engine: features - rva:{}, rvb:{}, rvv:{}", .{
        engine_features.has_rva,
        engine_features.has_rvb,
        engine_features.has_rvv,
    });

    engine_state = .available;
    return ntdll.STATUS_SUCCESS;
}

pub fn engineShutdown() void {
    engine_state = .uninitialized;
    translation_cache.invalidateAll();
    klog.info("riscv64_engine: shutdown complete", .{});
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
    var codegen = RV64CodeGen.init(out_buf);
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
                codegen.genAddi(10, 10, 0);
            },
            .add_rm8_r8, .add_rm16_r16, .add_rm32_r32, .add_rm64_r64 => {
                codegen.genAdd(10, 10, 11);
            },
            .sub_rm8_r8, .sub_rm16_r16, .sub_rm32_r32, .sub_rm64_r64 => {
                codegen.genSub(10, 10, 11);
            },
            .and_rm8_r8, .and_rm16_r16, .and_rm32_r32, .and_rm64_r64 => {
                codegen.genAnd(10, 10, 11);
            },
            .or_rm8_r8, .or_rm16_r16, .or_rm32_r32, .or_rm64_r64 => {
                codegen.genOr(10, 10, 11);
            },
            .xor_rm8_r8, .xor_rm16_r16, .xor_rm32_r32, .xor_rm64_r64 => {
                codegen.genXor(10, 10, 11);
            },
            .cmp_rm8_r8, .cmp_rm16_r16, .cmp_rm32_r32, .cmp_rm64_r64 => {
                codegen.genSub(0, 10, 11);
            },
            .jmp_rel8, .jmp_rel32 => {
                codegen.genNop();
            },
            .je_rel8, .je_rel32, .jz_rel8, .jz_rel32 => {
                codegen.genBeq(5, 6, 0);
            },
            .jne_rel8, .jne_rel32, .jnz_rel8, .jnz_rel32 => {
                codegen.genBnez(5, 0);
            },
            .jl_rel8, .jl_rel32, .jnge_rel8, .jnge_rel32 => {
                codegen.genBlt(5, 6, 0);
            },
            .jle_rel8, .jle_rel32, .jng_rel8, .jng_rel32 => {
                codegen.genBgt(6, 5, 0);
            },
            .jg_rel8, .jg_rel32, .jnle_rel8, .jnle_rel32 => {
                codegen.genBlt(6, 5, 0);
            },
            .jge_rel8, .jge_rel32, .jnl_rel8, .jnl_rel32 => {
                codegen.genBge(5, 6, 0);
            },
            .ja_rel8, .ja_rel32, .jnbe_rel8, .jnbe_rel32 => {
                codegen.genBgtu(5, 6, 0);
            },
            .jb_rel8, .jb_rel32, .jnae_rel8, .jnae_rel32 => {
                codegen.genBltu(5, 6, 0);
            },
            .jae_rel8, .jae_rel32, .jnb_rel8, .jnb_rel32 => {
                codegen.genBgeu(5, 6, 0);
            },
            .jbe_rel8, .jbe_rel32, .jna_rel8, .jna_rel32 => {
                codegen.genBgtu(6, 5, 0);
            },
            .jc_rel8, .jc_rel32 => {
                codegen.genBltu(5, 6, 0);
            },
            .jnc_rel8, .jnc_rel32 => {
                codegen.genBgeu(5, 6, 0);
            },
            .jo_rel8, .jo_rel32 => {
                codegen.genBnez(7, 0);
            },
            .jno_rel8, .jno_rel32 => {
                codegen.genBeq(7, 6, 0);
            },
            .js_rel8, .js_rel32 => {
                codegen.genBnez(8, 0);
            },
            .jns_rel8, .jns_rel32 => {
                codegen.genBeq(8, 6, 0);
            },
            .call_rel32 => {
                codegen.genNop();
            },
            .ret => {
                codegen.genRet();
                pos = x86_bytes.len;
                break;
            },
            .push_r32 => {
                codegen.genAddi(2, 2, -8);
                codegen.genSd(10, 2, 0);
            },
            .pop_r32 => {
                codegen.genLd(10, 2, 0);
                codegen.genAddi(2, 2, 8);
            },
            .syscall => {
                codegen.genEcall();
            },
            else => {
                codegen.genNop();
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

    if (code_size == 0) {
        return ntdll.STATUS_ACCESS_VIOLATION;
    }

    var host_buf: [8192]u8 = undefined;
    if (translateX86Block(x86_entry, x86_buf[0..code_size], &host_buf, undefined)) |gen_size| {
        if (gen_size > 0) {
            _ = translation_cache.insert(x86_entry, &host_buf, gen_size, 0);
        }
    }

    return ntdll.STATUS_SUCCESS;
}

fn readX86Memory(addr: u32, buf: []u8) usize {
    // 从当前 WOW64 进程的 x86 模拟地址空间读取
    const process = @import("../../../ps/process.zig");
    const ps = process.getCurrentProcess() orelse return 0;
    const asp = ps.address_space orelse return 0;

    // 零初始化缓冲区
    @memset(buf, 0);

    // 处理跨页面边界读取
    const page_size = @import("../../../arch.zig").impl.paging.page_size;
    const page_mask = page_size - 1;

    var offset: usize = 0;
    var current_addr = @as(u64, addr);

    while (offset < buf.len) {
        const page_start = current_addr & ~page_mask;
        const page_end = page_start + page_size;
        const remaining_in_page = page_end - current_addr;
        const chunk = @min(buf.len - offset, remaining_in_page);

        // 读取一页（使用 probe 模块安全探测）
        const probe = @import("../../../mm/probe.zig");
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
        .total_page_faults = total_page_faults,
        .total_syscalls = total_syscalls,
        .cache_hit_rate = rate,
    };
}

pub fn resetStats() void {
    total_translations = 0;
    total_translated_insns = 0;
    total_cache_hits = 0;
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

pub fn emulateSpecialInstruction(x86_addr: u32, insn_bytes: []const u8) ntdll.NTSTATUS {
    _ = x86_addr;
    _ = insn_bytes;
    return ntdll.STATUS_SUCCESS;
}
