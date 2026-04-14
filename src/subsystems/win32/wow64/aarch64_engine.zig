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
// Module: src/subsystems/win32/wow64/aarch64_engine.zig
// Purpose: ARM64 Dynamic Binary Translation Engine for x86-32/x86-64 code.
// This is an independent clean-room implementation.
// Reference: Microsoft ARM64EC architecture concept (clean-room, no code copied).

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
    has_neon: bool,
    has_sve: bool,
    has_dotprod: bool,
    uses_software_decoder: bool,
    uses_tb_cache: bool,
    uses_eflags_emulation: bool,
    reserved: u25,
};

var engine_features: EngineFeatures = .{
    .has_neon = false,
    .has_sve = false,
    .has_dotprod = false,
    .uses_software_decoder = true,
    .uses_tb_cache = true,
    .uses_eflags_emulation = true,
    .reserved = 0,
};

var total_translations: u64 = 0;
var total_translated_insns: u64 = 0;
var total_cache_hits: u64 = 0;
var total_eflags_emulations: u64 = 0;
var total_page_faults: u64 = 0;
var total_syscalls: u64 = 0;

pub const A64_REG = enum(u8) {
    x0,
    x1,
    x2,
    x3,
    x4,
    x5,
    x6,
    x7,
    x8,
    x9,
    x10,
    x11,
    x12,
    x13,
    x14,
    x15,
    x16,
    x17,
    x18,
    x19,
    x20,
    x21,
    x22,
    x23,
    x24,
    x25,
    x26,
    x27,
    x28,
    x29,
    x30,
    sp,
    w0,
    w1,
    w2,
    w3,
    w4,
    w5,
    w6,
    w7,
    w8,
    w9,
    w10,
    w11,
    w12,
    w13,
    w14,
    w15,
    w16,
    w17,
    w18,
    w19,
    w20,
    w21,
    w22,
    w23,
    w24,
    w25,
    w26,
    w27,
    w28,
    w29,
    w30,
    wsp,
    wzr,
    xzr,
};

pub const X86RegToA64Map = struct {
    pub const EAX: A64_REG = .w0;
    pub const ECX: A64_REG = .w1;
    pub const EDX: A64_REG = .w2;
    pub const EBX: A64_REG = .w3;
    pub const ESP: A64_REG = .wsp;
    pub const EBP: A64_REG = .w4;
    pub const ESI: A64_REG = .w5;
    pub const EDI: A64_REG = .w6;

    pub fn fromX86Reg32(reg: u8) A64_REG {
        return switch (reg) {
            0 => .w0,
            1 => .w1,
            2 => .w2,
            3 => .w3,
            4 => .wsp,
            5 => .w4,
            6 => .w5,
            7 => .w6,
            8...15 => @as(A64_REG, @enumFromInt(@as(u8, reg + 16))),
            else => .wzr,
        };
    }

    pub fn fromX86Reg64(reg: u8) A64_REG {
        return switch (reg) {
            0 => .x0,
            1 => .x1,
            2 => .x2,
            3 => .x3,
            4 => .sp,
            5 => .x4,
            6 => .x5,
            7 => .x6,
            8...15 => @as(A64_REG, @enumFromInt(@as(u8, reg + 8))),
            else => .xzr,
        };
    }

    pub fn fromX86Reg8(reg: u8) A64_REG {
        return switch (reg) {
            0 => .w0,
            1 => .w1,
            2 => .w2,
            3 => .w3,
            4 => .w0,
            5 => .w1,
            6 => .w2,
            7 => .w3,
            else => .wzr,
        };
    }
};

pub const A64CodeGen = struct {
    code_buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) A64CodeGen {
        return .{
            .code_buf = buf,
            .pos = 0,
        };
    }

    fn emit32(self: *A64CodeGen, value: u32) void {
        if (self.pos + 4 <= self.code_buf.len) {
            self.code_buf[self.pos .. self.pos + 4].* = @as([4]u8, @bitCast(@as(u32, @byteSwap(value))));
            self.pos += 4;
        }
    }

    fn emitRegOp(self: *A64CodeGen, sf: u1, op: u1, S: u1, shift: u2, imm6: u6, Rn: u5, Rd: u5, op2: u3, Ra: u5, Rm: u5) void {
        _ = imm6;
        const bits: u32 = (@as(u32, Rm) << 16) | (@as(u32, op2) << 12) |
            (@as(u32, Ra) << 10) | (@as(u32, Rd) << 5) |
            (@as(u32, Rn) << 0) | (@as(u32, shift) << 22) |
            (@as(u32, S) << 29) | (@as(u32, op) << 30) |
            (@as(u32, sf) << 31) | (0x8C << 24);
        self.emit32(bits);
    }

    pub fn genAdd(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5) void {
        const bits: u32 = (@as(u32, Rm) << 16) | (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x08 << 24) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn genAdds(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5) void {
        const bits: u32 = (@as(u32, Rm) << 16) | (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x08 << 24) | (@as(u32, sf) << 31) | (1 << 29);
        self.emit32(bits);
    }

    pub fn genSub(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5) void {
        const bits: u32 = (@as(u32, Rm) << 16) | (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x28 << 24) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn genSubs(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5) void {
        const bits: u32 = (@as(u32, Rm) << 16) | (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x28 << 24) | (@as(u32, sf) << 31) | (1 << 29);
        self.emit32(bits);
    }

    pub fn genAnd(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5) void {
        const bits: u32 = (@as(u32, Rm) << 16) | (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x08 << 24) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn genOrr(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5) void {
        const bits: u32 = (@as(u32, Rm) << 16) | (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x24 << 24) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn genEor(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5) void {
        const bits: u32 = (@as(u32, Rm) << 16) | (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x28 << 24) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn genMov(self: *A64CodeGen, sf: u1, Rd: u5, Rm: u5) void {
        self.genOrr(sf, Rd, 31, Rm);
    }

    pub fn genCmp(self: *A64CodeGen, sf: u1, Rn: u5, Rm: u5) void {
        self.genSubs(sf, 31, Rn, Rm);
    }

    pub fn genLdr(self: *A64CodeGen, sf: u1, Rt: u5, Rn: u5, offset: i9) void {
        const imm9: u9 = @as(u9, @bitCast(offset));
        const bits: u32 = (@as(u32, imm9) << 12) | (@as(u32, Rn) << 5) | (@as(u32, Rt) << 0) |
            (0x18 << 24) | (@as(u32, sf) << 30);
        self.emit32(bits);
    }

    pub fn genStr(self: *A64CodeGen, sf: u1, Rt: u5, Rn: u5, offset: i9) void {
        const imm9: u9 = @as(u9, @bitCast(offset));
        const bits: u32 = (@as(u32, imm9) << 12) | (@as(u32, Rn) << 5) | (@as(u32, Rt) << 0) |
            (0x18 << 24) | (@as(u32, sf) << 31) | (1 << 21);
        self.emit32(bits);
    }

    pub fn genLdrb(self: *A64CodeGen, Rt: u5, Rn: u5, offset: i9) void {
        const imm9: u9 = @as(u9, @bitCast(offset));
        const bits: u32 = (@as(u32, imm9) << 12) | (@as(u32, Rn) << 5) | (@as(u32, Rt) << 0) |
            (0x38 << 24);
        self.emit32(bits);
    }

    pub fn genStrb(self: *A64CodeGen, Rt: u5, Rn: u5, offset: i9) void {
        const imm9: u9 = @as(u9, @bitCast(offset));
        const bits: u32 = (@as(u32, imm9) << 12) | (@as(u32, Rn) << 5) | (@as(u32, Rt) << 0) |
            (0x38 << 24) | (1 << 21);
        self.emit32(bits);
    }

    pub fn genLdrh(self: *A64CodeGen, Rt: u5, Rn: u5, offset: i9) void {
        const imm9: u9 = @as(u9, @bitCast(offset));
        const bits: u32 = (@as(u32, imm9) << 12) | (@as(u32, Rn) << 5) | (@as(u32, Rt) << 0) |
            (0x3C << 24);
        self.emit32(bits);
    }

    pub fn genStrh(self: *A64CodeGen, Rt: u5, Rn: u5, offset: i9) void {
        const imm9: u9 = @as(u9, @bitCast(offset));
        const bits: u32 = (@as(u32, imm9) << 12) | (@as(u32, Rn) << 5) | (@as(u32, Rt) << 0) |
            (0x3C << 24) | (1 << 21);
        self.emit32(bits);
    }

    pub fn genB(self: *A64CodeGen, imm: i26) void {
        const imm26: u26 = @as(u26, @bitCast(imm));
        const bits: u32 = (0x14 << 24) | imm26;
        self.emit32(bits);
    }

    pub fn genBcc(self: *A64CodeGen, cond: u4, imm: i19) void {
        const imm19: u19 = @as(u19, @bitCast(imm));
        const bits: u32 = (0x54 << 24) | (@as(u32, cond) << 0) | (imm19 << 5);
        self.emit32(bits);
    }

    pub fn genBl(self: *A64CodeGen, imm: i26) void {
        const imm26: u26 = @as(u26, @bitCast(imm));
        const bits: u32 = (0x94 << 24) | imm26;
        self.emit32(bits);
    }

    pub fn genRet(self: *A64CodeGen) void {
        const bits: u32 = (0xD65F0000) | (@as(u32, 30) << 5);
        self.emit32(bits);
    }

    pub fn genSvc(self: *A64CodeGen, imm: u16) void {
        const bits: u32 = (0xD4000000) | (@as(u32, imm) << 5);
        self.emit32(bits);
    }

    pub fn genNop(self: *A64CodeGen) void {
        self.emit32(0xD503201F);
    }

    pub fn genCsinc(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5, cond: u4) void {
        const bits: u32 = (@as(u32, Rm) << 16) | (@as(u32, cond) << 12) |
            (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x26 << 24) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn genCsel(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5, cond: u4) void {
        const bits: u32 = (@as(u32, Rm) << 16) | (@as(u32, cond) << 12) |
            (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x24 << 24) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn genCset(self: *A64CodeGen, sf: u1, Rd: u5, cond: u4) void {
        self.genCsinc(sf, Rd, 31, 31, cond);
    }

    pub fn genBgt(self: *A64CodeGen, cond: u4, imm: i19) void {
        const imm19: u19 = @as(u19, @bitCast(imm));
        const bits: u32 = (0x54 << 24) | (@as(u32, cond) << 0) | (imm19 << 5) | (1 << 24);
        self.emit32(bits);
    }

    pub fn genMovz(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, shift: u2) void {
        const bits: u32 = (@as(u32, shift) << 22) | (@as(u32, Rn) << 5) |
            (@as(u32, Rd) << 0) | (0x69 << 24) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn genMovk(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, shift: u2) void {
        const bits: u32 = (@as(u32, shift) << 22) | (@as(u32, Rn) << 5) |
            (@as(u32, Rd) << 0) | (0x79 << 24) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn genSxtb(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5) void {
        self.genMovz(sf, Rd, Rn, 0);
        self.genSbfm(sf, Rd, Rn, 0, 7);
    }

    pub fn genSxth(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5) void {
        self.genSbfm(sf, Rd, Rn, 0, 15);
    }

    pub fn genSxtw(self: *A64CodeGen, Rd: u5, Rn: u5) void {
        self.genSbfm(1, Rd, Rn, 0, 31);
    }

    pub fn genSbfm(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, immr: u6, imms: u6) void {
        const bits: u32 = (@as(u32, imms) << 16) | (@as(u32, immr) << 10) |
            (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x26 << 24) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn genUbfm(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, immr: u6, imms: u6) void {
        const bits: u32 = (@as(u32, imms) << 16) | (@as(u32, immr) << 10) |
            (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x25 << 24) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn genMvn(self: *A64CodeGen, sf: u1, Rd: u5, Rm: u5) void {
        self.genOrr(sf, Rd, 31, Rm);
    }

    pub fn genLsl(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5) void {
        _ = Rm;
        const neg_imm: u6 = @truncate((~@as(u6, 0)) -% @as(u6, 0));
        self.genUbfm(sf, Rd, Rn, neg_imm, 63 -% neg_imm);
    }

    pub fn genAsr(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5) void {
        _ = sf;
        _ = self;
        _ = Rd;
        _ = Rn;
        _ = Rm;
    }

    pub fn genLsr(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5) void {
        _ = sf;
        _ = self;
        _ = Rd;
        _ = Rn;
        _ = Rm;
    }

    pub fn genCneg(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, cond: u4) void {
        self.genCsneg(sf, Rd, Rn, 31, cond);
    }

    pub fn genCsneg(self: *A64CodeGen, sf: u1, Rd: u5, Rn: u5, Rm: u5, cond: u4) void {
        const bits: u32 = (@as(u32, Rm) << 16) | (@as(u32, cond) << 12) |
            (@as(u32, Rn) << 5) | (@as(u32, Rd) << 0) |
            (0x26 << 24) | (1 << 15) | (@as(u32, sf) << 31);
        self.emit32(bits);
    }

    pub fn getCodeSize(self: *const A64CodeGen) usize {
        return self.pos;
    }
};

pub fn engineInit() ntdll.NTSTATUS {
    if (engine_state != .uninitialized) return ntdll.STATUS_SUCCESS;
    engine_state = .initializing;

    engine_features.has_neon = builtin.cpu.arch == .aarch64;
    engine_features.uses_eflags_emulation = true;
    engine_features.uses_tb_cache = true;

    translation_cache = tlb_cache.TranslationCache.init();

    klog.info("aarch64_engine: ARM64 translation engine initialized", .{});
    klog.info("aarch64_engine: features - neon:{}, sve:{}, dotprod:{}", .{
        engine_features.has_neon,
        engine_features.has_sve,
        engine_features.has_dotprod,
    });

    engine_state = .available;
    return ntdll.STATUS_SUCCESS;
}

pub fn engineShutdown() void {
    engine_state = .uninitialized;
    translation_cache.invalidateAll();
    klog.info("aarch64_engine: shutdown complete", .{});
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
    var codegen = A64CodeGen.init(out_buf);
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
                codegen.genMov(1, 0, 0);
            },
            .add_rm8_r8, .add_rm16_r16, .add_rm32_r32, .add_rm64_r64 => {
                codegen.genAdd(1, 0, 0, 1);
            },
            .sub_rm8_r8, .sub_rm16_r16, .sub_rm32_r32, .sub_rm64_r64 => {
                codegen.genSub(1, 0, 0, 1);
            },
            .and_rm8_r8, .and_rm16_r16, .and_rm32_r32, .and_rm64_r64 => {
                codegen.genAnd(1, 0, 0, 1);
            },
            .or_rm8_r8, .or_rm16_r16, .or_rm32_r32, .or_rm64_r64 => {
                codegen.genOrr(1, 0, 0, 1);
            },
            .xor_rm8_r8, .xor_rm16_r16, .xor_rm32_r32, .xor_rm64_r64 => {
                codegen.genEor(1, 0, 0, 1);
            },
            .cmp_rm8_r8, .cmp_rm16_r16, .cmp_rm32_r32, .cmp_rm64_r64 => {
                codegen.genCmp(1, 0, 1);
            },
            .jmp_rel8, .jmp_rel32 => {
                codegen.genNop();
            },
            .je_rel8, .je_rel32, .jz_rel8, .jz_rel32 => {
                codegen.genBcc(0, 0);
            },
            .jne_rel8, .jne_rel32, .jnz_rel8, .jnz_rel32 => {
                codegen.genBcc(1, 0);
            },
            .jl_rel8, .jl_rel32, .jnge_rel8, .jnge_rel32 => {
                codegen.genBcc(12, 0);
            },
            .jle_rel8, .jle_rel32, .jng_rel8, .jng_rel32 => {
                codegen.genBcc(14, 0);
            },
            .jg_rel8, .jg_rel32, .jnle_rel8, .jnle_rel32 => {
                codegen.genBcc(8, 0);
            },
            .jge_rel8, .jge_rel32, .jnl_rel8, .jnl_rel32 => {
                codegen.genBcc(10, 0);
            },
            .ja_rel8, .ja_rel32, .jnbe_rel8, .jnbe_rel32 => {
                codegen.genBcc(2, 0);
            },
            .jb_rel8, .jb_rel32, .jnae_rel8, .jnae_rel32 => {
                codegen.genBcc(3, 0);
            },
            .jae_rel8, .jae_rel32, .jnb_rel8, .jnb_rel32 => {
                codegen.genBcc(2, 0);
            },
            .jbe_rel8, .jbe_rel32, .jna_rel8, .jna_rel32 => {
                codegen.genBcc(3, 0);
            },
            .jc_rel8, .jc_rel32 => {
                codegen.genBcc(3, 0);
            },
            .jnc_rel8, .jnc_rel32 => {
                codegen.genBcc(2, 0);
            },
            .jo_rel8, .jo_rel32 => {
                codegen.genBcc(0xE, 0);
            },
            .jno_rel8, .jno_rel32 => {
                codegen.genBcc(0xF, 0);
            },
            .js_rel8, .js_rel32 => {
                codegen.genBcc(0xD, 0);
            },
            .jns_rel8, .jns_rel32 => {
                codegen.genBcc(0xC, 0);
            },
            .jpo_rel8, .jpo_rel32 => {
                codegen.genBcc(0xB, 0);
            },
            .jpe_rel8, .jpe_rel32 => {
                codegen.genBcc(0xA, 0);
            },
            .call_rel32 => {
                codegen.genBl(0);
            },
            .ret => {
                codegen.genRet();
                pos = x86_bytes.len;
                break;
            },
            .push_r32 => {
                codegen.genSub(1, 31, 31, 1);
                codegen.genStr(1, 0, 31, 0);
            },
            .pop_r32 => {
                codegen.genLdr(1, 0, 31, 0);
                codegen.genAdd(1, 31, 31, 1);
            },
            .syscall => {
                total_syscalls += 1;
                codegen.genSvc(0);
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

pub const EFLAGS_Operation = enum(u8) {
    op_add,
    op_sub,
    op_cmp,
    op_and,
    op_or,
    op_xor,
    op_test,
    op_shl,
    op_shr,
    op_inc,
    op_dec,
};

pub fn emulateEFLAGS(operation: EFLAGS_Operation, result: u64, src1: u64, src2: u64) u32 {
    total_eflags_emulations += 1;

    var eflags: u32 = 0;

    switch (operation) {
        .op_add, .op_sub, .op_cmp => {
            if (result == 0) eflags |= 0x40;
            if (@as(i64, @bitCast(result)) < 0) eflags |= 0x80;
            if (result > 0xFFFFFFFF) eflags |= 0x01;
            const result_neg = @as(i64, @bitCast(result)) < 0;
            const src1_neg = @as(i64, @bitCast(src1)) < 0;
            const src2_neg = @as(i64, @bitCast(src2)) < 0;
            if (result_neg != src1_neg and result_neg != src2_neg) {
                eflags |= 0x08;
            }
        },
        .op_and, .op_or, .op_xor, .op_test => {
            if (result == 0) eflags |= 0x40;
            if (@as(i64, @bitCast(result)) < 0) eflags |= 0x80;
        },
        .op_shl, .op_shr => {
            if (result == 0) eflags |= 0x40;
            if (@as(i64, @bitCast(result)) < 0) eflags |= 0x80;
        },
        .op_inc, .op_dec => {
            if (result == 0) eflags |= 0x40;
            if (@as(i64, @bitCast(result)) < 0) eflags |= 0x80;
        },
    }

    return eflags;
}

pub const TranslationStats = struct {
    total_translations: u64,
    total_translated_insns: u64,
    total_cache_hits: u64,
    total_eflags_emulations: u64,
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
        .total_eflags_emulations = total_eflags_emulations,
        .total_page_faults = total_page_faults,
        .total_syscalls = total_syscalls,
        .cache_hit_rate = rate,
    };
}

pub fn resetStats() void {
    total_translations = 0;
    total_translated_insns = 0;
    total_cache_hits = 0;
    total_eflags_emulations = 0;
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
