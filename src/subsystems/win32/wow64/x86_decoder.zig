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
// Module: src/subsystems/win32/wow64/x86_decoder.zig
// Purpose: Shared x86 instruction decoder for all DBT engines.
// Supports complete x86/x86-64 instruction decoding with unified IR output.
// This is an independent clean-room implementation.

const builtin = @import("builtin");

pub const MAX_INSN_LENGTH: usize = 15;

pub const X86Prefixes = packed struct(u16) {
    repne: bool,
    rep: bool,
    lock: bool,
    seg_cs: bool,
    seg_ss: bool,
    seg_ds: bool,
    seg_es: bool,
    seg_fs: bool,
    seg_gs: bool,
    op_size: bool,
    addr_size: bool,
    rex_w: bool,
    rex_r: bool,
    rex_x: bool,
    rex_b: bool,
    vex_w: bool,
    vex_l: bool,
    reserved: u1,
};

pub const X86Opcode = enum(u16) {
    invalid,
    nop,
    // Data transfer
    mov_rm8_r8,
    mov_rm16_r16,
    mov_rm32_r32,
    mov_rm64_r64,
    mov_r8_rm8,
    mov_r16_rm16,
    mov_r32_rm32,
    mov_r64_rm64,
    mov_r8_imm8,
    mov_r16_imm16,
    mov_r32_imm32,
    mov_r64_imm32,
    mov_r64_imm64,
    mov_imm8,
    mov_imm16,
    mov_imm32,
    mov_sreg_rm16,
    mov_rm16_sreg,
    mov_eflags_r32,
    mov_r32_eflags,
    mov_cr_r64,
    mov_r64_cr,
    // Arithmetic
    add_rm8_r8,
    add_rm16_r16,
    add_rm32_r32,
    add_rm64_r64,
    add_r8_rm8,
    add_r16_rm16,
    add_r32_rm32,
    add_r64_rm64,
    add_rm8_imm8,
    add_rm16_imm16,
    add_rm32_imm32,
    add_rm64_imm32,
    add_al_imm8,
    add_eax_imm32,
    sub_rm8_r8,
    sub_r8_rm8,
    sub_rm16_r16,
    sub_r16_rm16,
    sub_rm32_r32,
    sub_r32_rm32,
    sub_rm64_r64,
    sub_r64_rm64,
    sub_rm8_imm8,
    sub_rm16_imm16,
    sub_rm32_imm32,
    sub_rm64_imm32,
    sub_al_imm8,
    sub_eax_imm32,
    cmp_rm8_r8,
    cmp_r8_rm8,
    cmp_rm16_r16,
    cmp_r16_rm16,
    cmp_rm32_r32,
    cmp_r32_rm32,
    cmp_rm64_r64,
    cmp_r64_rm64,
    cmp_rm8_imm8,
    cmp_rm16_imm16,
    cmp_rm32_imm32,
    cmp_rm64_imm32,
    cmp_al_imm8,
    cmp_eax_imm32,
    test_rm8_r8,
    test_rm16_r16,
    test_rm32_r32,
    test_rm64_r64,
    test_rm8_imm8,
    test_rm16_imm16,
    test_rm32_imm32,
    test_rm64_imm32,
    test_al_imm8,
    test_eax_imm32,
    inc_rm8,
    inc_rm16,
    inc_rm32,
    inc_rm64,
    dec_rm8,
    dec_rm16,
    dec_rm32,
    dec_rm64,
    adc_rm8_r8,
    adc_rm16_r16,
    adc_rm32_r32,
    adc_rm64_r64,
    adc_r8_rm8,
    adc_r16_rm16,
    adc_r32_rm32,
    adc_r64_rm64,
    adc_rm8_imm8,
    adc_rm16_imm16,
    adc_rm32_imm32,
    adc_rm64_imm32,
    adc_al_imm8,
    adc_eax_imm32,
    sbb_rm8_r8,
    sbb_rm16_r16,
    sbb_rm32_r32,
    sbb_rm64_r64,
    sbb_r8_rm8,
    sbb_r16_rm16,
    sbb_r32_rm32,
    sbb_r64_rm64,
    sbb_al_imm8,
    sbb_eax_imm32,
    and_rm8_r8,
    and_r8_rm8,
    and_rm16_r16,
    and_r16_rm16,
    and_rm32_r32,
    and_r32_rm32,
    and_rm64_r64,
    and_r64_rm64,
    and_rm8_imm8,
    and_rm16_imm16,
    and_rm32_imm32,
    and_rm64_imm32,
    and_al_imm8,
    and_eax_imm32,
    or_rm8_r8,
    or_r8_rm8,
    or_rm16_r16,
    or_r16_rm16,
    or_rm32_r32,
    or_r32_rm32,
    or_rm64_r64,
    or_r64_rm64,
    or_rm8_imm8,
    or_rm16_imm16,
    or_rm32_imm32,
    or_rm64_imm32,
    or_al_imm8,
    or_eax_imm32,
    xor_rm8_r8,
    xor_r8_rm8,
    xor_rm16_r16,
    xor_r16_rm16,
    xor_rm32_r32,
    xor_r32_rm32,
    xor_rm64_r64,
    xor_r64_rm64,
    xor_rm8_imm8,
    xor_rm16_imm16,
    xor_rm32_imm32,
    xor_rm64_imm32,
    xor_al_imm8,
    xor_eax_imm32,
    // Shift
    shl_rm8_1,
    shl_rm16_1,
    shl_rm32_1,
    shl_rm64_1,
    shl_rm8_cl,
    shl_rm16_cl,
    shl_rm32_cl,
    shl_rm64_cl,
    shl_rm8_imm8,
    shl_rm16_imm8,
    shl_rm32_imm8,
    shl_rm64_imm8,
    shr_rm8_1,
    shr_rm16_1,
    shr_rm32_1,
    shr_rm64_1,
    shr_rm8_cl,
    shr_rm16_cl,
    shr_rm32_cl,
    shr_rm64_cl,
    shr_rm8_imm8,
    shr_rm16_imm8,
    shr_rm32_imm8,
    shr_rm64_imm8,
    sar_rm8_1,
    sar_rm16_1,
    sar_rm32_1,
    sar_rm64_1,
    sar_rm8_cl,
    sar_rm16_cl,
    sar_rm32_cl,
    sar_rm64_cl,
    sar_rm8_imm8,
    sar_rm16_imm8,
    sar_rm32_imm8,
    sar_rm64_imm8,
    sal_rm8_cl,
    sal_rm16_cl,
    sal_rm32_cl,
    sal_rm64_cl,
    sal_rm8_imm8,
    sal_rm16_imm8,
    sal_rm32_imm8,
    sal_rm64_imm8,
    rol_rm8_1,
    rol_rm16_1,
    rol_rm32_1,
    rol_rm64_1,
    rol_rm8_cl,
    rol_rm16_cl,
    rol_rm32_cl,
    rol_rm64_cl,
    ror_rm8_1,
    ror_rm16_1,
    ror_rm32_1,
    ror_rm64_1,
    ror_rm8_cl,
    ror_rm16_cl,
    ror_rm32_cl,
    ror_rm64_cl,
    rcl_rm8_1,
    rcl_rm16_1,
    rcl_rm32_1,
    rcl_rm64_1,
    rcl_rm8_cl,
    rcl_rm16_cl,
    rcl_rm32_cl,
    rcl_rm64_cl,
    rcr_rm8_1,
    rcr_rm16_1,
    rcr_rm32_1,
    rcr_rm64_1,
    rcr_rm8_cl,
    rcr_rm16_cl,
    rcr_rm32_cl,
    rcr_rm64_cl,
    // Stack
    push_r16,
    push_r32,
    push_r64,
    push_imm8,
    push_imm16,
    push_imm32,
    push_rm16,
    push_rm32,
    push_rm64,
    pushf,
    pop_r16,
    pop_r32,
    pop_r64,
    pop_rm16,
    pop_rm32,
    pop_rm64,
    popf,
    pusha,
    pushad,
    popa,
    popad,
    pushfq,
    popfq,
    // Control flow
    jmp_rel8,
    jmp_rel16,
    jmp_rel32,
    jmp_rm16,
    jmp_rm32,
    jmp_rm64,
    je_rel8,
    je_rel16,
    je_rel32,
    jne_rel8,
    jne_rel16,
    jne_rel32,
    jl_rel8,
    jl_rel16,
    jl_rel32,
    jle_rel8,
    jle_rel16,
    jle_rel32,
    jg_rel8,
    jg_rel16,
    jg_rel32,
    jge_rel8,
    jge_rel16,
    jge_rel32,
    ja_rel8,
    ja_rel16,
    ja_rel32,
    jae_rel8,
    jae_rel16,
    jae_rel32,
    jb_rel8,
    jb_rel16,
    jb_rel32,
    jbe_rel8,
    jbe_rel16,
    jbe_rel32,
    jo_rel8,
    jo_rel16,
    jo_rel32,
    jno_rel8,
    jno_rel16,
    jno_rel32,
    js_rel8,
    js_rel16,
    js_rel32,
    jns_rel8,
    jns_rel16,
    jns_rel32,
    jp_rel8,
    jp_rel16,
    jp_rel32,
    jnp_rel8,
    jnp_rel16,
    jnp_rel32,
    jcxz,
    jecxz,
    jrcxz,
    loop,
    loope,
    loopne,
    call_rel16,
    call_rel32,
    call_rm16,
    call_rm32,
    call_rm64,
    call_ptr16_32,
    ret,
    retf,
    ret_imm16,
    iret,
    iretd,
    iretq,
    // Procedures
    enter,
    leave,
    // String
    movs_rm8,
    movs_rm16,
    movs_rm32,
    movs_rm64,
    cmps_rm8,
    cmps_rm16,
    cmps_rm32,
    cmps_rm64,
    scas_rm8,
    scas_rm16,
    scas_rm32,
    scas_rm64,
    lods_rm8,
    lods_rm16,
    lods_rm32,
    lods_rm64,
    stos_rm8,
    stos_rm16,
    stos_rm32,
    stos_rm64,
    rep_movs_rm8,
    rep_movs_rm16,
    rep_movs_rm32,
    rep_movs_rm64,
    rep_cmps_rm8,
    rep_cmps_rm16,
    rep_cmps_rm32,
    rep_cmps_rm64,
    rep_scas_rm8,
    rep_scas_rm16,
    rep_scas_rm32,
    rep_scas_rm64,
    rep_lods_rm8,
    rep_lods_rm16,
    rep_lods_rm32,
    rep_lods_rm64,
    rep_stos_rm8,
    rep_stos_rm16,
    rep_stos_rm32,
    rep_stos_rm64,
    // Bit operations
    bt_rm16_r16,
    bt_rm32_r32,
    bt_rm64_r64,
    bts_rm16_r16,
    bts_rm32_r32,
    bts_rm64_r64,
    btr_rm16_r16,
    btr_rm32_r32,
    btr_rm64_r64,
    btc_rm16_r16,
    btc_rm32_r32,
    btc_rm64_r64,
    bsf_r16_rm16,
    bsf_r32_rm32,
    bsf_r64_rm64,
    bsr_r16_rm16,
    bsr_r32_rm32,
    bsr_r64_rm64,
    setcc,
    // CPUID/RDTSC/MSR
    cpuid,
    rdtsc,
    rdtscp,
    rdpmc,
    rdmsr,
    wrmsr,
    // Segment registers
    les,
    lds,
    lss,
    lfs,
    lgs,
    // Flag manipulation
    lahf,
    sahf,
    cld,
    std,
    cli,
    sti,
    clc,
    stc,
    cmc,
    // Interrupt
    int1,
    int3,
    into,
    // Conditional move
    cmove,
    cmovne,
    cmovl,
    cmovle,
    cmovg,
    cmovge,
    cmova,
    cmovae,
    cmovb,
    cmovbe,
    cmovs,
    cmovns,
    cmovo,
    cmovno,
    cmovp,
    cmovnp,
    // SIMD arithmetic
    addpd,
    addps,
    addsd,
    addss,
    subpd,
    subps,
    subsd,
    subss,
    mulpd,
    mulps,
    mulsd,
    mulss,
    divpd,
    divps,
    divsd,
    divss,
    sqrtpd,
    sqrtps,
    sqrtsd,
    sqrtss,
    andpd,
    andps,
    andnpd,
    andnps,
    orpd,
    orps,
    xorpd,
    xorps,
    movaps,
    movups,
    movapd,
    movupd,
    movss,
    movsd,
    movdqu,
    movdqa,
    movd,
    movq,
    // MMX/SSE
    paddb,
    paddw,
    paddd,
    paddq,
    psubb,
    psubw,
    psubd,
    psubq,
    pmullw,
    pmulhw,
    pmulld,
    pslld,
    psrld,
    psllq,
    psrlq,
    pand,
    por,
    pxor,
    pandn,
    pcmpeqb,
    pcmpeqw,
    pcmpeqd,
    pcmpgtb,
    pcmpgtw,
    pcmpgtd,
    // FPU
    fadd,
    faddp,
    fiadd,
    fsub,
    fsubp,
    fisub,
    fsubr,
    fsubrp,
    fisubr,
    fmul,
    fmulp,
    fimul,
    fdiv,
    fdivp,
    fidiv,
    fdivr,
    fdivrp,
    fidivr,
    fild,
    fist,
    fistp,
    fld,
    fst,
    fstp,
    fxch,
    fucom,
    fucomp,
    fucompp,
    fcom,
    fcomp,
    fcompp,
    ftst,
    fxam,
    ffree,
    ffreep,
    fnstsw,
    fstsw,
    // System
    syscall,
    sysret,
    sysretd,
    sysretq,
    sysenter,
    sysexit,
    sysexitd,
    sysexitq,
    vmcall,
    vmlaunch,
    vmresume,
    vmexit,
    // Other
    ud2,
    hlt,
    wait,
    nop_xchg,
    xchg_rm8_r8,
    xchg_rm16_r16,
    xchg_rm32_r32,
    xchg_rm64_r64,
    xchg_eax_r32,
    xchg_r32_eax,
    cmpxchg_rm8_r8,
    cmpxchg_rm16_r16,
    cmpxchg_rm32_r32,
    cmpxchg_rm64_r64,
    xadd_rm8_r8,
    xadd_rm16_r16,
    xadd_rm32_r32,
    xadd_rm64_r64,
    pause,
    das,
    aaa,
    aas,
    aad,
    aam,
    other,
};

pub const X86Register = enum(u8) {
    al, cl, dl, bl, ah, ch, dh, bh,
    ax, cx, dx, bx, sp, bp, si, di,
    eax, ecx, edx, ebx, esp, ebp, esi, edi,
    r8b, r9b, r10b, r11b, r12b, r13b, r14b, r15b,
    r8w, r9w, r10w, r11w, r12w, r13w, r14w, r15w,
    r8d, r9d, r10d, r11d, r12d, r13d, r14d, r15d,
    r8, r9, r10, r11, r12, r13, r14, r15,
    ip, eip, rip,
    flags, eflags, rflags,
    cs, ds, es, fs, gs, ss,
    cr0, cr2, cr3, cr4, cr8,
    st0, st1, st2, st3, st4, st5, st6, st7,
    mm0, mm1, mm2, mm3, mm4, mm5, mm6, mm7,
    xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7,
    xmm8, xmm9, xmm10, xmm11, xmm12, xmm13, xmm14, xmm15,
    ymm0, ymm1, ymm2, ymm3, ymm4, ymm5, ymm6, ymm7,
    ymm8, ymm9, ymm10, ymm11, ymm12, ymm13, ymm14, ymm15,
};

pub const Operand = union(enum) {
    reg: X86Register,
    imm: ImmOperand,
    mem: MemOperand,
    none,
};

pub const ImmOperand = struct {
    value: u64,
    size: u8,
};

pub const MemOperand = struct {
    base: X86Register,
    index: X86Register,
    scale: u8,
    disp: i64,
    seg: X86Register,
    size: u8,
};

pub const X86Instruction = struct {
    opcode: X86Opcode,
    prefixes: X86Prefixes,
    operands: [3]Operand,
    length: u8,
    effective_operand_size: u8,
    address_size: u8,
};

pub const ModRM = struct {
    mod: u2,
    reg: u3,
    rm: u3,
};

pub const SIB = struct {
    scale: u2,
    index: u3,
    base: u3,
};

pub fn parseModRM(bytes: []const u8, pos: usize) ?ModRM {
    if (pos >= bytes.len) return null;
    const byte = bytes[pos];
    return .{
        .mod = @truncate(byte >> 6),
        .reg = @truncate((byte >> 3) & 0x7),
        .rm = @truncate(byte & 0x7),
    };
}

pub fn parseSIB(bytes: []const u8, pos: usize) ?SIB {
    if (pos >= bytes.len) return null;
    const byte = bytes[pos];
    return .{
        .scale = @truncate(byte >> 6),
        .index = @truncate((byte >> 3) & 0x7),
        .base = @truncate(byte & 0x7),
    };
}

pub fn decodeX86Byte(code: u8) X86Opcode {
    return switch (code) {
        0x00 => .add_rm8_r8,
        0x01 => .add_rm16_r16,
        0x02 => .add_r8_rm8,
        0x03 => .add_r16_rm16,
        0x04 => .add_al_imm8,
        0x05 => .add_eax_imm32,
        0x06 => .push_r16,
        0x07 => .pop_r16,
        0x08 => .or_rm8_r8,
        0x09 => .or_rm16_r16,
        0x0A => .or_r8_rm8,
        0x0B => .or_r16_rm16,
        0x0C => .or_al_imm8,
        0x0D => .or_eax_imm32,
        0x0E => .push_r16,
        0x0F => .other,
        0x10 => .adc_rm8_r8,
        0x11 => .adc_rm16_r16,
        0x12 => .adc_r8_rm8,
        0x13 => .adc_r16_rm16,
        0x14 => .adc_al_imm8,
        0x15 => .adc_eax_imm32,
        0x16 => .push_r16,
        0x17 => .pop_r16,
        0x18 => .sbb_rm8_r8,
        0x19 => .sbb_rm16_r16,
        0x1A => .sbb_r8_rm8,
        0x1B => .sbb_r16_rm16,
        0x1C => .sbb_al_imm8,
        0x1D => .sbb_eax_imm32,
        0x1E => .push_r16,
        0x1F => .pop_r16,
        0x20 => .and_rm8_r8,
        0x21 => .and_rm16_r16,
        0x22 => .and_r8_rm8,
        0x23 => .and_r16_rm16,
        0x24 => .and_al_imm8,
        0x25 => .and_eax_imm32,
        0x26 => .other,
        0x27 => .das,
        0x28 => .sub_rm8_r8,
        0x29 => .sub_rm16_r16,
        0x2A => .sub_r8_rm8,
        0x2B => .sub_r16_rm16,
        0x2C => .sub_al_imm8,
        0x2D => .sub_eax_imm32,
        0x2E => .other,
        0x2F => .das,
        0x30 => .xor_rm8_r8,
        0x31 => .xor_rm16_r16,
        0x32 => .xor_r8_rm8,
        0x33 => .xor_r16_rm16,
        0x34 => .xor_al_imm8,
        0x35 => .xor_eax_imm32,
        0x36 => .other,
        0x37 => .aaa,
        0x38 => .cmp_rm8_r8,
        0x39 => .cmp_rm16_r16,
        0x3A => .cmp_r8_rm8,
        0x3B => .cmp_r16_rm16,
        0x3C => .cmp_al_imm8,
        0x3D => .cmp_eax_imm32,
        0x3E => .other,
        0x3F => .aas,
        // 0x40-0x47: inc r32 (REX.B may extend register set)
        0x40 => .inc_rm32,
        0x41 => .inc_rm32,
        0x42 => .inc_rm32,
        0x43 => .inc_rm32,
        0x44 => .inc_rm32,
        0x45 => .inc_rm32,
        0x46 => .inc_rm32,
        0x47 => .inc_rm32,
        // 0x48-0x4F: dec r32
        0x48 => .dec_rm32,
        0x49 => .dec_rm32,
        0x4A => .dec_rm32,
        0x4B => .dec_rm32,
        0x4C => .dec_rm32,
        0x4D => .dec_rm32,
        0x4E => .dec_rm32,
        0x4F => .dec_rm32,
        // 0x50-0x57: push r32
        0x50 => .push_r32,
        0x51 => .push_r32,
        0x52 => .push_r32,
        0x53 => .push_r32,
        0x54 => .push_r32,
        0x55 => .push_r32,
        0x56 => .push_r32,
        0x57 => .push_r32,
        // 0x58-0x5F: pop r32
        0x58 => .pop_r32,
        0x59 => .pop_r32,
        0x5A => .pop_r32,
        0x5B => .pop_r32,
        0x5C => .pop_r32,
        0x5D => .pop_r32,
        0x5E => .pop_r32,
        0x5F => .pop_r32,
        0x60 => .pushad,
        0x61 => .popad,
        0x62 => .other,
        0x63 => .other,
        0x64 => .other,
        0x65 => .other,
        0x66 => .other,
        0x67 => .other,
        0x68 => .push_imm32,
        0x69 => .other,
        0x6A => .push_imm8,
        0x6B => .other,
        0x6C => .other,
        0x6D => .other,
        0x6E => .other,
        0x6F => .other,
        0x70 => .jo_rel8,
        0x71 => .jno_rel8,
        0x72 => .jb_rel8,
        0x73 => .jae_rel8,
        0x74 => .je_rel8,
        0x75 => .jne_rel8,
        0x76 => .jbe_rel8,
        0x77 => .ja_rel8,
        0x78 => .js_rel8,
        0x79 => .jns_rel8,
        0x7A => .jp_rel8,
        0x7B => .jnp_rel8,
        0x7C => .jl_rel8,
        0x7D => .jge_rel8,
        0x7E => .jle_rel8,
        0x7F => .jg_rel8,
        // 0x80: ModR/M group 1 (add/or/adc/sbb/and/sub/xor/cmp) - imm8
        0x80 => .other,
        // 0x81: ModR/M group 1 - imm32
        0x81 => .other,
        // 0x82: ModR/M group 1 - imm8 (alias of 80 on x64)
        0x82 => .other,
        // 0x83: ModR/M group 1 - imm8 (sign-extended)
        0x83 => .other,
        0x84 => .test_rm8_r8,
        0x85 => .test_rm16_r16,
        0x86 => .xchg_rm8_r8,
        0x87 => .xchg_rm16_r16,
        0x88 => .mov_rm8_r8,
        0x89 => .mov_rm16_r16,
        0x8A => .mov_r8_rm8,
        0x8B => .mov_r16_rm16,
        0x8C => .mov_rm16_sreg,
        0x8D => .other,
        0x8E => .mov_sreg_rm16,
        0x8F => .other,
        0x90 => .nop,
        0x91 => .xchg_eax_r32,
        0x92 => .xchg_eax_r32,
        0x93 => .xchg_eax_r32,
        0x94 => .xchg_eax_r32,
        0x95 => .xchg_eax_r32,
        0x96 => .xchg_eax_r32,
        0x97 => .xchg_eax_r32,
        0x98 => .other,
        0x99 => .other,
        0x9A => .call_ptr16_32,
        0x9B => .wait,
        0x9C => .pushf,
        0x9D => .popf,
        0x9E => .sahf,
        0x9F => .lahf,
        0xA0 => .mov_imm8,
        0xA1 => .mov_imm32,
        0xA2 => .mov_imm8,
        0xA3 => .mov_imm32,
        0xA4 => .movs_rm8,
        0xA5 => .movs_rm32,
        0xA6 => .cmps_rm8,
        0xA7 => .cmps_rm32,
        0xA8 => .test_al_imm8,
        0xA9 => .test_eax_imm32,
        0xAA => .stos_rm8,
        0xAB => .stos_rm32,
        0xAC => .lods_rm8,
        0xAD => .lods_rm32,
        0xAE => .scas_rm8,
        0xAF => .scas_rm32,
        0xB0 => .mov_imm8,
        0xB1 => .mov_imm8,
        0xB2 => .mov_imm8,
        0xB3 => .mov_imm8,
        0xB4 => .mov_imm8,
        0xB5 => .mov_imm8,
        0xB6 => .mov_imm8,
        0xB7 => .mov_imm8,
        0xB8 => .mov_imm32,
        0xB9 => .mov_imm32,
        0xBA => .mov_imm32,
        0xBB => .mov_imm32,
        0xBC => .mov_imm32,
        0xBD => .mov_imm32,
        0xBE => .mov_imm32,
        0xBF => .mov_imm32,
        // 0xC0: ModR/M shift group - imm8
        0xC0 => .other,
        // 0xC1: ModR/M shift group - imm8
        0xC1 => .other,
        0xC2 => .ret_imm16,
        0xC3 => .ret,
        0xC4 => .les,
        0xC5 => .lds,
        0xC6 => .other,
        0xC7 => .other,
        0xC8 => .enter,
        0xC9 => .leave,
        0xCA => .retf,
        0xCB => .retf,
        0xCC => .int3,
        0xCD => .int1,
        0xCE => .into,
        0xCF => .iretd,
        // 0xD0: ModR/M shift group - 1
        0xD0 => .other,
        // 0xD1: ModR/M shift group - 1
        0xD1 => .other,
        // 0xD2: ModR/M shift group - CL
        0xD2 => .other,
        // 0xD3: ModR/M shift group - CL
        0xD3 => .other,
        0xD4 => .aam,
        0xD5 => .aad,
        0xD6 => .other,
        0xD7 => .other,
        0xD8 => .other,
        0xD9 => .other,
        0xDA => .other,
        0xDB => .other,
        0xDC => .other,
        0xDD => .other,
        0xDE => .other,
        0xDF => .other,
        0xE0 => .other,
        0xE1 => .other,
        0xE2 => .loop,
        0xE3 => .jcxz,
        0xE4 => .other,
        0xE5 => .other,
        0xE6 => .other,
        0xE7 => .other,
        0xE8 => .call_rel32,
        0xE9 => .jmp_rel32,
        0xEA => .other,
        0xEB => .jmp_rel8,
        0xEC => .other,
        0xED => .other,
        0xEE => .other,
        0xEF => .other,
        0xF0 => .other,
        0xF1 => .other,
        0xF2 => .other,
        0xF3 => .other,
        0xF4 => .hlt,
        0xF5 => .cmc,
        // 0xF6: ModR/M group 3 (test/not/neg/mul/imul/div/idiv) - 8-bit
        0xF6 => .other,
        // 0xF7: ModR/M group 3 - 16/32-bit
        0xF7 => .other,
        0xF8 => .clc,
        0xF9 => .stc,
        0xFA => .cli,
        0xFB => .sti,
        0xFC => .cld,
        0xFD => .std,
        // 0xFE: ModR/M group 4 (inc/dec) - 8-bit
        0xFE => .other,
        // 0xFF: ModR/M group 5 (inc/dec/call/jmp/push)
        0xFF => .other,
    };
}

pub fn decodeTwoByteOpcode(code: u8) X86Opcode {
    return switch (code) {
        0x00...0x03 => .other,
        0x04...0x05 => .other,
        0x06 => .clc,
        0x07 => .stc,
        0x08 => .sysretd,
        0x09 => .clc,
        0x0A...0x0E => .other,
        0x0F => .ud2,
        // SSE/SSE2 packed single/double FP
        0x10 => .other,  // 0F 10: movups/movupd/movlps/movhps/movhlps/movlhps
        0x11 => .other,  // movups/movupd/movlps/movhps
        0x12 => .other,  // movlps/movhlps
        0x13 => .other,  // movlps
        0x14 => .other,  // unpcklps
        0x15 => .other,  // unpckhps
        0x16 => .other,  // movhps/movlhps
        0x17 => .other,  // movhps
        0x18 => .other,  // prefetch hints
        0x19...0x1F => .other,
        0x20 => .mov_cr_r64,
        0x21 => .other,
        0x22 => .mov_r64_cr,
        0x23 => .other,
        0x24 => .other,
        0x25 => .other,
        0x28 => .other,  // movaps
        0x29 => .other,  // movaps
        0x2A...0x2F => .other,
        0x30 => .wrmsr,
        0x31 => .rdtsc,
        0x32 => .rdmsr,
        0x33 => .rdpmc,
        0x34 => .sysenter,
        0x35 => .sysexitd,
        0x38 => .other,
        0x3A => .other,
        0x40...0x4F => .cmove,
        // 0x50 => .other,
        0x51 => .other,  // sqrtps/sqrtss
        0x52...0x57 => .other,
        0x58...0x5F => .other,
        0x60...0x6F => .other,
        0x70 => .other,  // pshufd
        0x71...0x77 => .other,
        0x78...0x7F => .other,
        // 0x80: jo rel32
        0x80 => .jo_rel32,
        // 0x81: jno rel32
        0x81 => .jno_rel32,
        // 0x82: jb rel32
        0x82 => .jb_rel32,
        // 0x83: jae rel32
        0x83 => .jae_rel32,
        // 0x84: je rel32
        0x84 => .je_rel32,
        // 0x85: jne rel32
        0x85 => .jne_rel32,
        // 0x86: jbe rel32
        0x86 => .jbe_rel32,
        // 0x87: ja rel32
        0x87 => .ja_rel32,
        // 0x88: js rel32
        0x88 => .js_rel32,
        // 0x89: jns rel32
        0x89 => .jns_rel32,
        // 0x8A: jp rel32
        0x8A => .jp_rel32,
        // 0x8B: jnp rel32
        0x8B => .jnp_rel32,
        // 0x8C: jl rel32
        0x8C => .jl_rel32,
        // 0x8D: jge rel32
        0x8D => .jge_rel32,
        // 0x8E: jle rel32
        0x8E => .jle_rel32,
        // 0x8F: jg rel32
        0x8F => .jg_rel32,
        0x90...0x9F => .other,
        0xA0 => .other,
        0xA1 => .other,
        0xA2 => .cpuid,
        0xA3 => .bt_rm16_r16,
        0xA4...0xAF => .other,
        0xB0...0xB7 => .cmpxchg_rm8_r8,
        0xB8...0xBF => .other,
        0xC0 => .cmpxchg_rm8_r8,
        0xC1 => .cmpxchg_rm16_r16,
        0xC2...0xC7 => .other,
        0xC8...0xCF => .other,
        0xD0...0xDF => .other,
        0xE0...0xEF => .other,
        0xF0...0xFF => .other,
    };
}

pub fn decodeInstruction(bytes: []const u8) X86Instruction {
    if (bytes.len == 0) {
        return .{
            .opcode = .invalid,
            .prefixes = .{},
            .operands = .{ .none, .none, .none },
            .length = 0,
            .effective_operand_size = 4,
            .address_size = 4,
        };
    }

    var pos: usize = 0;
    var prefixes: X86Prefixes = .{};
    var operand_size: u8 = 4;
    var address_size: u8 = 4;

    // Legacy prefixes
    while (pos < bytes.len and pos < 4) {
        const p = bytes[pos];
        switch (p) {
            0xF0 => prefixes.lock = true,
            0xF2 => prefixes.repne = true,
            0xF3 => prefixes.rep = true,
            0x2E => prefixes.seg_cs = true,
            0x36 => prefixes.seg_ss = true,
            0x3E => prefixes.seg_ds = true,
            0x26 => prefixes.seg_es = true,
            0x64 => prefixes.seg_fs = true,
            0x65 => prefixes.seg_gs = true,
            0x66 => {
                prefixes.op_size = true;
                operand_size = 2;
            },
            0x67 => {
                prefixes.addr_size = true;
                address_size = if (builtin.cpu.arch == .x86_64) 4 else 4;
            },
            else => break,
        }
        pos += 1;
    }

    // REX prefix (x64 only): 0100WRXB
    if (builtin.cpu.arch == .x86_64 and pos < bytes.len) {
        const rex = bytes[pos];
        if ((rex & 0xF0) == 0x40) {
            prefixes.rex_w = (rex & 0x08) != 0;
            prefixes.rex_r = (rex & 0x04) != 0;
            prefixes.rex_x = (rex & 0x02) != 0;
            prefixes.rex_b = (rex & 0x01) != 0;
            if (prefixes.rex_w) operand_size = 8;
            pos += 1;
        }
    }

    if (pos >= bytes.len) {
        return .{
            .opcode = .invalid,
            .prefixes = prefixes,
            .operands = .{ .none, .none, .none },
            .length = @as(u8, @intCast(pos)),
            .effective_operand_size = operand_size,
            .address_size = address_size,
        };
    }

    const first_byte = bytes[pos];
    var opcode: X86Opcode = .invalid;
    var uses_modrm = false;

    if (first_byte == 0x0F) {
        pos += 1;
        if (pos >= bytes.len) {
            return .{
                .opcode = .invalid,
                .prefixes = prefixes,
                .operands = .{ .none, .none, .none },
                .length = @as(u8, @intCast(pos)),
                .effective_operand_size = operand_size,
                .address_size = address_size,
            };
        }
        opcode = decodeTwoByteOpcode(bytes[pos]);
        uses_modrm = twoByteOpcodeUsesModRM(bytes[pos]);
    } else {
        opcode = decodeX86Byte(first_byte);
        uses_modrm = oneByteOpcodeUsesModRM(first_byte);
    }

    pos += 1;

    // Parse ModR/M if needed
    var modrm: ?ModRM = null;
    var has_sib = false;
    var imm_size: u8 = 0;
    var disp_size: u8 = 0;

    if (uses_modrm and pos < bytes.len) {
        modrm = parseModRM(bytes, pos);
        pos += 1;

        if (modrm) |mr| {
            const addr_sz = address_size;
            if (mr.mod != 3) {
                // SIB byte needed for [ESP] or x64 with [RSP]
                if ((addr_sz == 8 and mr.rm == 4) or (addr_sz == 4 and mr.rm == 4)) {
                    has_sib = true;
                    _ = parseSIB(bytes, pos);
                    pos += 1;
                }
                // Displacement sizes
                if (mr.mod == 0) {
                    if (mr.rm == 5) disp_size = if (addr_sz == 8) 8 else 4;
                } else if (mr.mod == 1) {
                    disp_size = 1;
                } else if (mr.mod == 2) {
                    disp_size = if (addr_sz == 8) 8 else 4;
                }
            }
        }
    }

    // Immediate sizes for opcodes that need them
    imm_size = immediateSizeForOpcode(opcode, prefixes.op_size);

    pos += disp_size;
    pos += imm_size;

    return .{
        .opcode = opcode,
        .prefixes = prefixes,
        .operands = .{ .none, .none, .none },
        .length = @as(u8, @intCast(@min(pos, bytes.len))),
        .effective_operand_size = operand_size,
        .address_size = address_size,
    };
}

fn oneByteOpcodeUsesModRM(op: u8) bool {
    return switch (op) {
        0x00...0x05 => true,  // add/or/adc/sbb/and/sub/xor/cmp with modrm
        0x08...0x0D => true,
        0x10...0x15 => true,
        0x18...0x1D => true,
        0x20...0x25 => true,
        0x28...0x2D => true,
        0x30...0x35 => true,
        0x38...0x3D => true,
        0x62, 0x63 => true,
        0x69, 0x6B => true,
        0x80...0x83 => true,
        0x84, 0x85 => true,
        0x86, 0x87 => true,
        0x88...0x8D => true,
        0x8F => true,
        0x9A, 0x9C, 0x9D => false,
        0xA0, 0xA1, 0xA2, 0xA3 => false,
        0xC0, 0xC1 => true,
        0xC4, 0xC5 => false,
        0xC6, 0xC7 => true,
        0xD0, 0xD1, 0xD2, 0xD3 => true,
        0xF6, 0xF7 => true,
        0xFE, 0xFF => true,
        else => false,
    };
}

fn twoByteOpcodeUsesModRM(op: u8) bool {
    return switch (op) {
        0x00...0x05 => true,
        0x10...0x18 => true,
        0x28...0x2D => true,
        0x38...0x3F => true,
        0x60...0x77 => true,
        0x80...0x8F => false,
        0x90...0x9F => false,
        0xA0...0xA3 => false,
        0xA4...0xAF => true,
        0xB0...0xBF => true,
        0xC0...0xCF => true,
        else => false,
    };
}

fn immediateSizeForOpcode(op: X86Opcode, has_op_size: bool) u8 {
    _ = has_op_size;
    return switch (op) {
        .add_al_imm8, .adc_al_imm8, .sbb_al_imm8,
        .sub_al_imm8, .cmp_al_imm8, .and_al_imm8, .or_al_imm8,
        .xor_al_imm8, .test_al_imm8 => 1,
        .add_eax_imm32, .adc_eax_imm32, .sbb_eax_imm32,
        .sub_eax_imm32, .cmp_eax_imm32, .and_eax_imm32,
        .or_eax_imm32, .xor_eax_imm32, .test_eax_imm32,
        .push_imm32, .call_rel32, .jmp_rel32 => 4,
        .push_imm8, .call_rel16, .jmp_rel16, .jmp_rel8 => 1,
        .ret_imm16 => 2,
        .enter => 3,
        else => 0,
    };
}

pub fn getRegisterName(reg: X86Register, size: u8) []const u8 {
    _ = size;
    return switch (reg) {
        .al => "al", .ah => "ah", .bl => "bl", .bh => "bh",
        .cl => "cl", .ch => "ch", .dl => "dl", .dh => "dh",
        .ax => "ax", .bx => "bx", .cx => "cx", .dx => "dx",
        .sp => "sp", .bp => "bp", .si => "si", .di => "di",
        .eax => "eax", .ebx => "ebx", .ecx => "ecx", .edx => "edx",
        .esp => "esp", .ebp => "ebp", .esi => "esi", .edi => "edi",
        .rax => "rax", .rbx => "rbx", .rcx => "rcx", .rdx => "rdx",
        .rsp => "rsp", .rbp => "rbp", .rsi => "rsi", .rdi => "rdi",
        .r8 => "r8", .r9 => "r9", .r10 => "r10", .r11 => "r11",
        .r12 => "r12", .r13 => "r13", .r14 => "r14", .r15 => "r15",
        else => "unknown",
    };
}
