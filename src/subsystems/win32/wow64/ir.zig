// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/ir.zig
// Purpose: Intermediate Representation for x86 to host architecture translation.
// This is an independent clean-room implementation.

const decoder = @import("x86_decoder.zig");
const builtin = @import("builtin");

pub const MAX_IR_INSNS: usize = 256;
pub const MAX_BASIC_BLOCKS: usize = 32;

pub const IROp = enum(u8) {
    nop,
    // Data movement
    mov,
    mov_imm,
    movzx,
    movsx,
    movsxd,
    // Arithmetic
    add,
    addc,
    sub,
    sbb,
    mul,
    imul,
    div,
    idiv,
    neg,
    abs_op,
    // Logical
    and_op,
    or_op,
    xor_op,
    not_op,
    // Shifts
    shl,
    shr,
    sar,
    rol,
    ror,
    rcl,
    rcr,
    // Bit operations
    bt,
    bts,
    btr,
    btc,
    bsf,
    bsr,
    // Comparison
    cmp_eq,
    cmp_ne,
    cmp_lt,
    cmp_le,
    cmp_gt,
    cmp_ge,
    cmp_ugt,
    cmp_uge,
    cmp_ult,
    cmp_ule,
    test_op,
    // Control flow
    br,
    br_cond,
    br_z,
    br_nz,
    br_ltz,
    br_lez,
    br_gtz,
    br_gez,
    call,
    ret_insn,
    syscall_insn,
    sysret,
    // Memory
    load_u8,
    load_u16,
    load_u32,
    load_u64,
    load_i8,
    load_i16,
    load_i32,
    load_i64,
    store_u8,
    store_u16,
    store_u32,
    store_u64,
    // String operations
    movs,
    cmps,
    scas,
    lods,
    stos,
    // FPU
    fld,
    fst,
    fadd,
    fsub,
    fmul,
    fdiv,
    // Flag operations
    setcc,
    getcc,
    push_flags,
    pop_flags,
    // Segment
    push_seg,
    pop_seg,
    // Special
    halt,
    pause,
    cpuid,
    rdtsc,
};

pub const IRReg = enum(u8) {
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
    zero,
    sp,
    pc,
    // EFLAGS virtual registers
    flag_z,
    flag_nz,
    flag_s,
    flag_ns,
    flag_c,
    flag_nc,
    flag_o,
    flag_no,
    flag_p,
    flag_np,
    // Condition codes
    cc_e,
    cc_ne,
    cc_l,
    cc_le,
    cc_g,
    cc_ge,
    cc_b,
    cc_be,
    cc_a,
    cc_ae,
    cc_cs,
    cc_hi,
};

pub const IRCondition = enum(u4) {
    always,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    cs,
    hi,
    lo,
    vs,
    vc,
    s,
    ns,
    p,
    np,
};

pub const IRInstruction = struct {
    op: IROp,
    dest: IRReg,
    src1: IRReg,
    src2: IRReg,
    imm: i64,
    cond: IRCondition,
    pub fn new(op: IROp, dest: IRReg, src1: IRReg, src2: IRReg) IRInstruction {
        return .{
            .op = op,
            .dest = dest,
            .src1 = src1,
            .src2 = src2,
            .imm = 0,
            .cond = .always,
        };
    }
};

pub const BasicBlock = struct {
    start_addr: u32,
    end_addr: u32,
    instructions: [MAX_IR_INSNS]IRInstruction,
    insn_count: usize = 0,
    is_exit_block: bool = false,
    pub fn addInsn(self: *BasicBlock, insn: IRInstruction) void {
        if (self.insn_count < MAX_IR_INSNS) {
            self.instructions[self.insn_count] = insn;
            self.insn_count += 1;
        }
    }
};

pub const ControlFlowGraph = struct {
    blocks: [MAX_BASIC_BLOCKS]BasicBlock,
    block_count: usize = 0,
};

pub const IRBuilder = struct {
    instructions: [MAX_IR_INSNS]IRInstruction,
    count: usize = 0,

    pub fn reset(self: *IRBuilder) void {
        self.count = 0;
    }

    pub fn add(self: *IRBuilder, op: IROp, dest: IRReg, src1: IRReg, src2: IRReg) void {
        if (self.count < MAX_IR_INSNS) {
            self.instructions[self.count] = .{
                .op = op,
                .dest = dest,
                .src1 = src1,
                .src2 = src2,
                .imm = 0,
                .cond = .always,
            };
            self.count += 1;
        }
    }

    pub fn addImm(self: *IRBuilder, op: IROp, dest: IRReg, src1: IRReg, imm_val: i64) void {
        if (self.count < MAX_IR_INSNS) {
            self.instructions[self.count] = .{
                .op = op,
                .dest = dest,
                .src1 = src1,
                .src2 = .zero,
                .imm = imm_val,
                .cond = .always,
            };
            self.count += 1;
        }
    }

    pub fn addBranch(self: *IRBuilder, cond: IRCondition, target: i64) void {
        if (self.count < MAX_IR_INSNS) {
            self.instructions[self.count] = .{
                .op = .br_cond,
                .dest = .zero,
                .src1 = .zero,
                .src2 = .zero,
                .imm = target,
                .cond = cond,
            };
            self.count += 1;
        }
    }

    pub fn addCondBranch(self: *IRBuilder, cond: IRCondition, target_true: i64, target_false: i64) void {
        if (self.count >= MAX_IR_INSNS) return;
        self.instructions[self.count] = .{
            .op = .br_cond,
            .dest = .zero,
            .src1 = .zero,
            .src2 = .zero,
            .imm = target_true,
            .cond = cond,
        };
        self.count += 1;
        if (self.count >= MAX_IR_INSNS) return;
        self.instructions[self.count] = .{
            .op = .br,
            .dest = .zero,
            .src1 = .zero,
            .src2 = .zero,
            .imm = target_false,
            .cond = .always,
        };
        self.count += 1;
    }

    pub fn addCall(self: *IRBuilder, target: IRReg) void {
        if (self.count < MAX_IR_INSNS) {
            self.instructions[self.count] = .{
                .op = .call,
                .dest = .zero,
                .src1 = target,
                .src2 = .zero,
                .imm = 0,
                .cond = .always,
            };
            self.count += 1;
        }
    }

    pub fn addRet(self: *IRBuilder) void {
        self.add(.ret_insn, .zero, .zero, .zero);
    }

    pub fn addSyscall(self: *IRBuilder) void {
        self.add(.syscall_insn, .zero, .zero, .zero);
    }

    pub fn addLoad(self: *IRBuilder, dest: IRReg, base: IRReg, offset: i64, size: u8) void {
        if (self.count >= MAX_IR_INSNS) return;
        const op: IROp = switch (size) {
            1 => .load_u8,
            2 => .load_u16,
            4 => .load_u32,
            8 => .load_u64,
            else => .load_u32,
        };
        self.instructions[self.count] = .{
            .op = op,
            .dest = dest,
            .src1 = base,
            .src2 = .zero,
            .imm = offset,
            .cond = .always,
        };
        self.count += 1;
    }

    pub fn addStore(self: *IRBuilder, src: IRReg, base: IRReg, offset: i64, size: u8) void {
        if (self.count >= MAX_IR_INSNS) return;
        const op: IROp = switch (size) {
            1 => .store_u8,
            2 => .store_u16,
            4 => .store_u32,
            8 => .store_u64,
            else => .store_u32,
        };
        self.instructions[self.count] = .{
            .op = op,
            .dest = .zero,
            .src1 = src,
            .src2 = base,
            .imm = offset,
            .cond = .always,
        };
        self.count += 1;
    }

    pub fn addCompare(self: *IRBuilder, src1: IRReg, src2: IRReg) void {
        self.add(.cmp_eq, .flag_z, src1, src2);
        self.add(.cmp_lt, .flag_s, src1, src2);
    }

    pub fn finalize(self: *const IRBuilder) []const IRInstruction {
        return self.instructions[0..self.count];
    }
};

pub const X86ToIRRegMap = struct {
    const EAX: IRReg = .r0;
    const ECX: IRReg = .r1;
    const EDX: IRReg = .r2;
    const EBX: IRReg = .r3;
    const ESP: IRReg = .sp;
    const EBP: IRReg = .r4;
    const ESI: IRReg = .r5;
    const EDI: IRReg = .r6;

    pub fn fromX86Reg(x86_reg: u8) IRReg {
        return switch (x86_reg) {
            0 => .r0,
            1 => .r1,
            2 => .r2,
            3 => .r3,
            4 => .sp,
            5 => .r4,
            6 => .r5,
            7 => .r6,
            8...31 => @as(IRReg, @enumFromInt(x86_reg)),
            else => .zero,
        };
    }
};

pub fn translateX86ToIR(insn_bytes: []const u8, entry_addr: u32) IRBuilder {
    var builder = IRBuilder{};
    var pos: usize = 0;
    var current_addr = entry_addr;

    while (pos < insn_bytes.len) {
        const remaining = insn_bytes[pos..];
        if (remaining.len == 0) break;

        const insn = decoder.decodeInstruction(remaining);
        const opcode = insn.opcode;
        //const op_size = insn.effective_operand_size;
        //const prefixes = insn.prefixes;

        switch (opcode) {
            // ── 数据移动 ────────────────────────────────────────────
            .mov_rm8_r8, .mov_rm16_r16, .mov_rm32_r32, .mov_rm64_r64 => {
                builder.add(.mov, .r0, .r1, .zero);
            },
            .mov_r8_rm8, .mov_r16_rm16, .mov_r32_rm32, .mov_r64_rm64 => {
                builder.add(.mov, .r0, .r1, .zero);
            },
            .mov_imm8 => {
                if (pos + 1 < insn_bytes.len) {
                    const imm = @as(i64, @bitCast(insn_bytes[pos + 1]));
                    builder.addImm(.mov_imm, .r0, .zero, imm);
                    pos += 1;
                    current_addr += 1;
                }
            },
            .mov_imm16 => {
                if (pos + 2 <= insn_bytes.len) {
                    const imm = @as(i64, @bitCast(@as(u16, insn_bytes[pos + 1] | (@as(u16, insn_bytes[pos + 2]) << 8))));
                    builder.addImm(.mov_imm, .r0, .zero, imm);
                    pos += 2;
                    current_addr += 2;
                }
            },
            .mov_imm32 => {
                if (pos + 4 <= insn_bytes.len) {
                    const imm = @as(i64, @bitCast(@as(u32, insn_bytes[pos + 1] |
                        (@as(u32, insn_bytes[pos + 2]) << 8) |
                        (@as(u32, insn_bytes[pos + 3]) << 16) |
                        (@as(u32, insn_bytes[pos + 4]) << 24))));
                    builder.addImm(.mov_imm, .r0, .zero, imm);
                    pos += 4;
                    current_addr += 4;
                }
            },
            // ── 算术操作 ────────────────────────────────────────────
            .add_rm8_r8, .add_rm16_r16, .add_rm32_r32, .add_rm64_r64 => {
                builder.add(.add, .r0, .r0, .r1);
            },
            .add_r8_rm8, .add_r16_rm16, .add_r32_rm32, .add_r64_rm64 => {
                builder.add(.add, .r0, .r0, .r1);
            },
            .add_al_imm8 => {
                if (pos + 1 < insn_bytes.len) {
                    const imm = @as(i64, @bitCast(insn_bytes[pos + 1]));
                    builder.addImm(.add, .r0, .r0, imm);
                    pos += 1;
                    current_addr += 1;
                }
            },
            .add_eax_imm32 => {
                if (pos + 4 <= insn_bytes.len) {
                    const imm = @as(i64, @bitCast(@as(u32, insn_bytes[pos + 1] |
                        (@as(u32, insn_bytes[pos + 2]) << 8) |
                        (@as(u32, insn_bytes[pos + 3]) << 16) |
                        (@as(u32, insn_bytes[pos + 4]) << 24))));
                    builder.addImm(.add, .r0, .r0, imm);
                    pos += 4;
                    current_addr += 4;
                }
            },
            .sub_rm8_r8, .sub_rm16_r16, .sub_rm32_r32, .sub_rm64_r64 => {
                builder.add(.sub, .r0, .r0, .r1);
            },
            .sub_r8_rm8, .sub_r16_rm16, .sub_r32_rm32, .sub_r64_rm64 => {
                builder.add(.sub, .r0, .r0, .r1);
            },
            .sub_al_imm8 => {
                if (pos + 1 < insn_bytes.len) {
                    const imm = @as(i64, @bitCast(insn_bytes[pos + 1]));
                    builder.addImm(.sub, .r0, .r0, imm);
                    pos += 1;
                    current_addr += 1;
                }
            },
            .sub_eax_imm32 => {
                if (pos + 4 <= insn_bytes.len) {
                    const imm = @as(i64, @bitCast(@as(u32, insn_bytes[pos + 1] |
                        (@as(u32, insn_bytes[pos + 2]) << 8) |
                        (@as(u32, insn_bytes[pos + 3]) << 16) |
                        (@as(u32, insn_bytes[pos + 4]) << 24))));
                    builder.addImm(.sub, .r0, .r0, imm);
                    pos += 4;
                    current_addr += 4;
                }
            },
            .adc_rm8_r8, .adc_rm16_r16, .adc_rm32_r32, .adc_rm64_r64 => {
                builder.add(.addc, .r0, .r0, .r1);
            },
            .sbb_rm8_r8, .sbb_rm16_r16, .sbb_rm32_r32, .sbb_rm64_r64 => {
                builder.add(.sbb, .r0, .r0, .r1);
            },
            .neg => builder.add(.neg, .r0, .r0, .zero),
            // ── 逻辑操作 ────────────────────────────────────────────
            .xor_rm8_r8, .xor_rm16_r16, .xor_rm32_r32, .xor_rm64_r64 => {
                builder.add(.xor_op, .r0, .r0, .r1);
            },
            .xor_r8_rm8, .xor_r16_rm16, .xor_r32_rm32, .xor_r64_rm64 => {
                builder.add(.xor_op, .r0, .r0, .r1);
            },
            .xor_al_imm8 => {
                if (pos + 1 < insn_bytes.len) {
                    const imm = @as(i64, @bitCast(insn_bytes[pos + 1]));
                    builder.addImm(.xor_op, .r0, .r0, imm);
                    pos += 1;
                    current_addr += 1;
                }
            },
            .xor_eax_imm32 => {
                if (pos + 4 <= insn_bytes.len) {
                    const imm = @as(i64, @bitCast(@as(u32, insn_bytes[pos + 1] |
                        (@as(u32, insn_bytes[pos + 2]) << 8) |
                        (@as(u32, insn_bytes[pos + 3]) << 16) |
                        (@as(u32, insn_bytes[pos + 4]) << 24))));
                    builder.addImm(.xor_op, .r0, .r0, imm);
                    pos += 4;
                    current_addr += 4;
                }
            },
            .and_rm8_r8, .and_rm16_r16, .and_rm32_r32, .and_rm64_r64 => {
                builder.add(.and_op, .r0, .r0, .r1);
            },
            .and_r8_rm8, .and_r16_rm16, .and_r32_rm32, .and_r64_rm64 => {
                builder.add(.and_op, .r0, .r0, .r1);
            },
            .and_al_imm8 => {
                if (pos + 1 < insn_bytes.len) {
                    const imm = @as(i64, @bitCast(insn_bytes[pos + 1]));
                    builder.addImm(.and_op, .r0, .r0, imm);
                    pos += 1;
                    current_addr += 1;
                }
            },
            .and_eax_imm32 => {
                if (pos + 4 <= insn_bytes.len) {
                    const imm = @as(i64, @bitCast(@as(u32, insn_bytes[pos + 1] |
                        (@as(u32, insn_bytes[pos + 2]) << 8) |
                        (@as(u32, insn_bytes[pos + 3]) << 16) |
                        (@as(u32, insn_bytes[pos + 4]) << 24))));
                    builder.addImm(.and_op, .r0, .r0, imm);
                    pos += 4;
                    current_addr += 4;
                }
            },
            .or_rm8_r8, .or_rm16_r16, .or_rm32_r32, .or_rm64_r64 => {
                builder.add(.or_op, .r0, .r0, .r1);
            },
            .or_r8_rm8, .or_r16_rm16, .or_r32_rm32, .or_r64_rm64 => {
                builder.add(.or_op, .r0, .r0, .r1);
            },
            .or_al_imm8 => {
                if (pos + 1 < insn_bytes.len) {
                    const imm = @as(i64, @bitCast(insn_bytes[pos + 1]));
                    builder.addImm(.or_op, .r0, .r0, imm);
                    pos += 1;
                    current_addr += 1;
                }
            },
            .or_eax_imm32 => {
                if (pos + 4 <= insn_bytes.len) {
                    const imm = @as(i64, @bitCast(@as(u32, insn_bytes[pos + 1] |
                        (@as(u32, insn_bytes[pos + 2]) << 8) |
                        (@as(u32, insn_bytes[pos + 3]) << 16) |
                        (@as(u32, insn_bytes[pos + 4]) << 24))));
                    builder.addImm(.or_op, .r0, .r0, imm);
                    pos += 4;
                    current_addr += 4;
                }
            },
            // ── 比较和测试 ──────────────────────────────────────────
            .cmp_rm8_r8, .cmp_rm16_r16, .cmp_rm32_r32, .cmp_rm64_r64 => {
                builder.add(.cmp_eq, .flag_z, .r0, .r1);
                builder.add(.cmp_lt, .flag_s, .r0, .r1);
            },
            .cmp_r8_rm8, .cmp_r16_rm16, .cmp_r32_rm32, .cmp_r64_rm64 => {
                builder.add(.cmp_eq, .flag_z, .r0, .r1);
                builder.add(.cmp_lt, .flag_s, .r0, .r1);
            },
            .cmp_al_imm8 => {
                if (pos + 1 < insn_bytes.len) {
                    const imm = @as(i64, @bitCast(insn_bytes[pos + 1]));
                    builder.addImm(.cmp_eq, .flag_z, .r0, imm);
                    pos += 1;
                    current_addr += 1;
                }
            },
            .cmp_eax_imm32 => {
                if (pos + 4 <= insn_bytes.len) {
                    const imm = @as(i64, @bitCast(@as(u32, insn_bytes[pos + 1] |
                        (@as(u32, insn_bytes[pos + 2]) << 8) |
                        (@as(u32, insn_bytes[pos + 3]) << 16) |
                        (@as(u32, insn_bytes[pos + 4]) << 24))));
                    builder.addImm(.cmp_eq, .flag_z, .r0, imm);
                    builder.addImm(.cmp_lt, .flag_s, .r0, imm);
                    pos += 4;
                    current_addr += 4;
                }
            },
            .test_rm8_r8, .test_rm16_r16, .test_rm32_r32, .test_rm64_r64 => {
                builder.add(.test_op, .flag_z, .r0, .r1);
            },
            .test_al_imm8 => {
                if (pos + 1 < insn_bytes.len) {
                    const imm = @as(i64, @bitCast(insn_bytes[pos + 1]));
                    builder.addImm(.test_op, .flag_z, .r0, imm);
                    pos += 1;
                    current_addr += 1;
                }
            },
            .test_eax_imm32 => {
                if (pos + 4 <= insn_bytes.len) {
                    const imm = @as(i64, @bitCast(@as(u32, insn_bytes[pos + 1] |
                        (@as(u32, insn_bytes[pos + 2]) << 8) |
                        (@as(u32, insn_bytes[pos + 3]) << 16) |
                        (@as(u32, insn_bytes[pos + 4]) << 24))));
                    builder.addImm(.test_op, .flag_z, .r0, imm);
                    pos += 4;
                    current_addr += 4;
                }
            },
            // ── 移位操作 ───────────────────────────────────────────
            .shl_rm8_cl, .shl_rm16_cl, .shl_rm32_cl, .shl_rm64_cl => {
                builder.add(.shl, .r0, .r0, .r1);
            },
            .shr_rm8_cl, .shr_rm16_cl, .shr_rm32_cl, .shr_rm64_cl => {
                builder.add(.shr, .r0, .r0, .r1);
            },
            .sar_rm8_cl, .sar_rm16_cl, .sar_rm32_cl, .sar_rm64_cl => {
                builder.add(.sar, .r0, .r0, .r1);
            },
            .rol_rm8_cl, .rol_rm16_cl, .rol_rm32_cl, .rol_rm64_cl => {
                builder.add(.rol, .r0, .r0, .r1);
            },
            .ror_rm8_cl, .ror_rm16_cl, .ror_rm32_cl, .ror_rm64_cl => {
                builder.add(.ror, .r0, .r0, .r1);
            },
            // ── 标志操作 ───────────────────────────────────────────
            .clc => builder.add(.setcc, .cc_cs, .zero, .zero),
            .stc => builder.add(.setcc, .cc_cs, .r31, .zero),
            .std => builder.add(.setcc, .cc_cs, .r31, .zero),
            .cld => builder.add(.setcc, .cc_cs, .zero, .zero),
            .lahf => builder.add(.getcc, .r0, .cc_hi, .zero),
            .sahf => builder.add(.setcc, .cc_hi, .r0, .zero),
            .pushf => builder.add(.push_flags, .zero, .zero, .zero),
            .popf => builder.add(.pop_flags, .r0, .zero, .zero),
            // ── 栈操作 ─────────────────────────────────────────────
            .push_r16, .push_r32, .push_r64 => {
                builder.add(.push_flags, .zero, X86ToIRRegMap.fromX86Reg32(opcode >> 8), .zero);
            },
            .push_imm8 => {
                if (pos + 1 < insn_bytes.len) {
                    const imm = @as(i64, @bitCast(insn_bytes[pos + 1]));
                    builder.addImm(.push_flags, .zero, .zero, imm);
                    pos += 1;
                    current_addr += 1;
                }
            },
            .push_imm16, .push_imm32 => {
                if (pos + (if (opcode == .push_imm32) 4 else 2) <= insn_bytes.len) {
                    const sz: usize = if (opcode == .push_imm32) 4 else 2;
                    const imm = if (sz == 4)
                        @as(i64, @bitCast(@as(u32, insn_bytes[pos + 1] |
                            (@as(u32, insn_bytes[pos + 2]) << 8) |
                            (@as(u32, insn_bytes[pos + 3]) << 16) |
                            (@as(u32, insn_bytes[pos + 4]) << 24))))
                    else
                        @as(i64, @bitCast(@as(u16, insn_bytes[pos + 1] | (@as(u16, insn_bytes[pos + 2]) << 8))));
                    builder.addImm(.push_flags, .zero, .zero, imm);
                    pos += sz;
                    current_addr += @as(u32, @intCast(sz));
                }
            },
            .push_rm16, .push_rm32, .push_rm64 => {
                builder.add(.push_flags, .zero, .r0, .zero);
            },
            .pop_r16, .pop_r32, .pop_r64 => {
                builder.add(.pop_flags, X86ToIRRegMap.fromX86Reg32(opcode >> 8), .zero, .zero);
            },
            .pop_rm16, .pop_rm32, .pop_rm64 => {
                builder.add(.pop_flags, .r0, .zero, .zero);
            },
            .pushad, .pusha => builder.add(.push_flags, .zero, .zero, .zero),
            .popad, .popa => builder.add(.pop_flags, .zero, .zero, .zero),
            // ── 控制流 ─────────────────────────────────────────────
            .jo_rel8, .jno_rel8, .jb_rel8, .jae_rel8, .je_rel8, .jne_rel8, .jbe_rel8, .ja_rel8, .js_rel8, .jns_rel8, .jp_rel8, .jnp_rel8, .jl_rel8, .jge_rel8, .jle_rel8, .jg_rel8 => {
                const offset = @as(i8, @bitCast(insn_bytes[pos + 1]));
                const target = @as(i64, @bitCast(current_addr)) + 2 + @as(i64, @bitCast(offset));
                const cond = jccToIRCondition(opcode, .rel8);
                builder.addBranch(cond, target);
                pos += 1;
                current_addr += 1;
            },
            .jo_rel16, .jno_rel16, .jb_rel16, .jae_rel16, .je_rel16, .jne_rel16, .jbe_rel16, .ja_rel16, .js_rel16, .jns_rel16, .jp_rel16, .jnp_rel16, .jl_rel16, .jge_rel16, .jle_rel16, .jg_rel16 => {
                if (pos + 2 <= insn_bytes.len) {
                    const offset = @as(i16, @bitCast(@as(u16, insn_bytes[pos + 1] | (@as(u16, insn_bytes[pos + 2]) << 8))));
                    const target = @as(i64, @bitCast(current_addr)) + 3 + @as(i64, @bitCast(offset));
                    const cond = jccToIRCondition(opcode, .rel16);
                    builder.addBranch(cond, target);
                    pos += 2;
                    current_addr += 2;
                }
            },
            .jo_rel32, .jno_rel32, .jb_rel32, .jae_rel32, .je_rel32, .jne_rel32, .jbe_rel32, .ja_rel32, .js_rel32, .jns_rel32, .jp_rel32, .jnp_rel32, .jl_rel32, .jge_rel32, .jle_rel32, .jg_rel32 => {
                pos += 1;
                if (pos + 4 <= insn_bytes.len) {
                    const offset = @as(i32, @bitCast(@as(u32, insn_bytes[pos + 0] |
                        (@as(u32, insn_bytes[pos + 1]) << 8) |
                        (@as(u32, insn_bytes[pos + 2]) << 16) |
                        (@as(u32, insn_bytes[pos + 3]) << 24))));
                    const target = @as(i64, @bitCast(current_addr)) + 5 + @as(i64, @bitCast(offset));
                    const cond = jccToIRCondition(opcode, .rel32);
                    builder.addBranch(cond, target);
                    pos += 3;
                    current_addr += 4;
                }
            },
            .jmp_rel8 => {
                if (pos + 1 < insn_bytes.len) {
                    const offset = @as(i8, @bitCast(insn_bytes[pos + 1]));
                    const target = @as(i64, @bitCast(current_addr)) + 2 + @as(i64, @bitCast(offset));
                    builder.addBranch(.always, target);
                    pos += 1;
                    current_addr += 1;
                }
            },
            .jmp_rel32 => {
                pos += 1;
                if (pos + 4 <= insn_bytes.len) {
                    const offset = @as(i32, @bitCast(@as(u32, insn_bytes[pos + 0] |
                        (@as(u32, insn_bytes[pos + 1]) << 8) |
                        (@as(u32, insn_bytes[pos + 2]) << 16) |
                        (@as(u32, insn_bytes[pos + 3]) << 24))));
                    const target = @as(i64, @bitCast(current_addr)) + 5 + @as(i64, @bitCast(offset));
                    builder.addBranch(.always, target);
                    pos += 3;
                    current_addr += 4;
                }
            },
            .call_rel32 => {
                pos += 1;
                if (pos + 4 <= insn_bytes.len) {
                    const offset = @as(i32, @bitCast(@as(u32, insn_bytes[pos + 0] |
                        (@as(u32, insn_bytes[pos + 1]) << 8) |
                        (@as(u32, insn_bytes[pos + 2]) << 16) |
                        (@as(u32, insn_bytes[pos + 3]) << 24))));
                    const target = @as(i64, @bitCast(current_addr)) + 5 + @as(i64, @bitCast(offset));
                    builder.addImm(.mov, .r31, .zero, target);
                    builder.addCall(.r31);
                    pos += 3;
                    current_addr += 4;
                }
            },
            .call_rm16, .call_rm32, .call_rm64 => {
                builder.addCall(.r0);
            },
            .ret => builder.addRet(),
            .ret_imm16 => {
                builder.addRet();
                if (pos + 1 < insn_bytes.len) {
                    pos += 1;
                    current_addr += 1;
                }
            },
            .jcxz => {
                if (pos + 1 < insn_bytes.len) {
                    const offset = @as(i8, @bitCast(insn_bytes[pos + 1]));
                    const target = @as(i64, @bitCast(current_addr)) + 2 + @as(i64, @bitCast(offset));
                    builder.addBranch(.cc_hi, target);
                    pos += 1;
                    current_addr += 1;
                }
            },
            .loop, .loope, .loopne => {
                if (pos + 1 < insn_bytes.len) {
                    const offset = @as(i8, @bitCast(insn_bytes[pos + 1]));
                    const target = @as(i64, @bitCast(current_addr)) + 2 + @as(i64, @bitCast(offset));
                    if (opcode == .loopne) {
                        builder.addBranch(.cc_ne, target);
                    } else if (opcode == .loope) {
                        builder.addBranch(.cc_e, target);
                    } else {
                        builder.addBranch(.always, target);
                    }
                    pos += 1;
                    current_addr += 1;
                }
            },
            // ── 字符串操作 ─────────────────────────────────────────
            .movs_rm8 => builder.add(.movs, .r0, .r0, .zero),
            .movs_rm16 => builder.add(.movs, .r0, .r0, .zero),
            .movs_rm32 => builder.add(.movs, .r0, .r0, .zero),
            .movs_rm64 => builder.add(.movs, .r0, .r0, .zero),
            .cmps_rm8 => builder.add(.cmps, .r0, .r0, .zero),
            .cmps_rm16 => builder.add(.cmps, .r0, .r0, .zero),
            .cmps_rm32 => builder.add(.cmps, .r0, .r0, .zero),
            .cmps_rm64 => builder.add(.cmps, .r0, .r0, .zero),
            .scas_rm8 => builder.add(.scas, .r0, .r0, .zero),
            .scas_rm16 => builder.add(.scas, .r0, .r0, .zero),
            .scas_rm32 => builder.add(.scas, .r0, .r0, .zero),
            .scas_rm64 => builder.add(.scas, .r0, .r0, .zero),
            .lods_rm8 => builder.add(.lods, .r0, .r0, .zero),
            .lods_rm16 => builder.add(.lods, .r0, .r0, .zero),
            .lods_rm32 => builder.add(.lods, .r0, .r0, .zero),
            .lods_rm64 => builder.add(.lods, .r0, .r0, .zero),
            .stos_rm8 => builder.add(.stos, .r0, .r0, .zero),
            .stos_rm16 => builder.add(.stos, .r0, .r0, .zero),
            .stos_rm32 => builder.add(.stos, .r0, .r0, .zero),
            .stos_rm64 => builder.add(.stos, .r0, .r0, .zero),
            // ── 特殊指令 ─────────────────────────────────────────────
            .syscall => builder.addSyscall(),
            .sysenter, .int3, .int1, .into => builder.add(.syscall_insn, .zero, .zero, .zero),
            .cpuid => builder.add(.cpuid, .zero, .zero, .zero),
            .rdtsc => builder.add(.rdtsc, .zero, .zero, .zero),
            .nop => builder.add(.nop, .zero, .zero, .zero),
            .hlt => builder.add(.halt, .zero, .zero, .zero),
            .pause => builder.add(.pause, .zero, .zero, .zero),
            // 其他未知操作码 -> nop
            else => builder.add(.nop, .zero, .zero, .zero),
        }

        // Advance past the instruction if not already done
        if (opcode != .mov_imm8 and opcode != .mov_imm16 and opcode != .mov_imm32 and
            opcode != .add_al_imm8 and opcode != .add_eax_imm32 and
            opcode != .sub_al_imm8 and opcode != .sub_eax_imm32 and
            opcode != .xor_al_imm8 and opcode != .xor_eax_imm32 and
            opcode != .and_al_imm8 and opcode != .and_eax_imm32 and
            opcode != .or_al_imm8 and opcode != .or_eax_imm32 and
            opcode != .cmp_al_imm8 and opcode != .cmp_eax_imm32 and
            opcode != .test_al_imm8 and opcode != .test_eax_imm32 and
            opcode != .push_imm8 and opcode != .call_rel32 and
            opcode != .jmp_rel8 and opcode != .jmp_rel32 and
            opcode != .jo_rel8 and opcode != .jno_rel8 and
            opcode != .jl_rel8 and opcode != .jge_rel8 and
            opcode != .jle_rel8 and opcode != .jg_rel8 and
            opcode != .jb_rel8 and opcode != .jae_rel8 and
            opcode != .je_rel8 and opcode != .jne_rel8 and
            opcode != .js_rel8 and opcode != .jns_rel8 and
            opcode != .jp_rel8 and opcode != .jnp_rel8 and
            opcode != .jo_rel16 and opcode != .jno_rel16 and
            opcode != .jl_rel16 and opcode != .jge_rel16 and
            opcode != .jle_rel16 and opcode != .jg_rel16 and
            opcode != .jb_rel16 and opcode != .jae_rel16 and
            opcode != .je_rel16 and opcode != .jne_rel16 and
            opcode != .js_rel16 and opcode != .jns_rel16 and
            opcode != .jp_rel16 and opcode != .jnp_rel16 and
            opcode != .jo_rel32 and opcode != .jno_rel32 and
            opcode != .jl_rel32 and opcode != .jge_rel32 and
            opcode != .jle_rel32 and opcode != .jg_rel32 and
            opcode != .jb_rel32 and opcode != .jae_rel32 and
            opcode != .je_rel32 and opcode != .jne_rel32 and
            opcode != .js_rel32 and opcode != .jns_rel32 and
            opcode != .jp_rel32 and opcode != .jnp_rel32 and
            opcode != .push_imm16 and opcode != .push_imm32 and
            opcode != .ret_imm16 and opcode != .jcxz and
            opcode != .loop and opcode != .loope and opcode != .loopne)
        {
            const len = insn.length;
            pos += if (len > 0) @as(usize, len) else 1;
            current_addr += if (len > 0) @as(u32, @intCast(len)) else 1;
        }
    }

    return builder;
}

const JccRelType = enum { rel8, rel16, rel32 };

fn jccToIRCondition(op: decoder.X86Opcode, rel_type: JccRelType) IRCondition {
    _ = rel_type;
    return switch (op) {
        .jo_rel8, .jo_rel16, .jo_rel32 => .vs,
        .jno_rel8, .jno_rel16, .jno_rel32 => .vc,
        .jb_rel8, .jb_rel16, .jb_rel32 => .cc,
        .jae_rel8, .jae_rel16, .jae_rel32 => .cs,
        .je_rel8, .je_rel16, .je_rel32 => .eq,
        .jne_rel8, .jne_rel16, .jne_rel32 => .ne,
        .jbe_rel8, .jbe_rel16, .jbe_rel32 => .cc_be,
        .ja_rel8, .ja_rel16, .ja_rel32 => .cc_a,
        .js_rel8, .js_rel16, .js_rel32 => .s,
        .jns_rel8, .jns_rel16, .jns_rel32 => .ns,
        .jp_rel8, .jp_rel16, .jp_rel32 => .p,
        .jnp_rel8, .jnp_rel16, .jnp_rel32 => .np,
        .jl_rel8, .jl_rel16, .jl_rel32 => .lt,
        .jge_rel8, .jge_rel16, .jge_rel32 => .ge,
        .jle_rel8, .jle_rel16, .jle_rel32 => .le,
        .jg_rel8, .jg_rel16, .jg_rel32 => .gt,
        else => .always,
    };
}
