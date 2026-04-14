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

/*
 * MIPS64 CP0 register and bit definitions
 * Reference: MIPS64 Architecture For Programmers Volume III (public spec)
 */

#ifndef _MIPS_DEFS_H
#define _MIPS_DEFS_H

/* CP0 Register numbers (for mfc0/mtc0 $reg, <number>) */
#define CP0_INDEX       $0
#define CP0_RANDOM      $1
#define CP0_ENTRYLO0    $2
#define CP0_ENTRYLO1    $3
#define CP0_CONTEXT     $4
#define CP0_PAGEMASK    $5
#define CP0_WIRED       $6
#define CP0_BADVADDR    $8
#define CP0_COUNT       $9
#define CP0_ENTRYHI     $10
#define CP0_COMPARE     $11
#define CP0_STATUS      $12
#define CP0_CAUSE       $13
#define CP0_EPC         $14
#define CP0_PRID        $15
#define CP0_EBASE       $15, 1
#define CP0_CONFIG      $16
#define CP0_XCONTEXT    $20
#define CP0_ERROREPC    $30

/* CP0 Status register bits */
#define ST_IE           (1 << 0)
#define ST_EXL          (1 << 1)
#define ST_ERL          (1 << 2)
#define ST_KSU_MASK     (3 << 3)
#define ST_UX           (1 << 5)
#define ST_SX           (1 << 6)
#define ST_KX           (1 << 7)
#define ST_IM0          (1 << 8)
#define ST_IM1          (1 << 9)
#define ST_IM2          (1 << 10)
#define ST_IM3          (1 << 11)
#define ST_IM4          (1 << 12)
#define ST_IM5          (1 << 13)
#define ST_IM6          (1 << 14)
#define ST_IM7          (1 << 15)
#define ST_IM_ALL       (0xFF << 8)
#define ST_BEV          (1 << 22)
#define ST_FR           (1 << 26)
#define ST_CU0          (1 << 28)
#define ST_CU1          (1 << 29)

/* CP0 Cause register bits */
#define CAUSE_EXCCODE_SHIFT  2
#define CAUSE_EXCCODE_MASK   (0x1F << CAUSE_EXCCODE_SHIFT)
#define CAUSE_IP_SHIFT       8
#define CAUSE_IP_MASK        (0xFF << CAUSE_IP_SHIFT)
#define CAUSE_IV             (1 << 23)
#define CAUSE_BD             (1 << 31)

/* Exception codes (CP0.Cause.ExcCode) */
#define EXC_INT         0
#define EXC_MOD         1
#define EXC_TLBL        2
#define EXC_TLBS        3
#define EXC_ADEL        4
#define EXC_ADES        5
#define EXC_SYS         8
#define EXC_BP          9
#define EXC_RI          10
#define EXC_CPU         11
#define EXC_OV          12

/* Trap frame offsets (must match MipsTrapFrame in traps.zig) */
#define TF_ZERO         0
#define TF_AT           8
#define TF_V0           16
#define TF_V1           24
#define TF_A0           32
#define TF_A1           40
#define TF_A2           48
#define TF_A3           56
#define TF_A4           64
#define TF_A5           72
#define TF_A6           80
#define TF_A7           88
#define TF_T0           96
#define TF_T1           104
#define TF_T2           112
#define TF_T3           120
#define TF_S0           128
#define TF_S1           136
#define TF_S2           144
#define TF_S3           152
#define TF_S4           160
#define TF_S5           168
#define TF_S6           176
#define TF_S7           184
#define TF_T8           192
#define TF_T9           200
#define TF_K0           208
#define TF_K1           216
#define TF_GP           224
#define TF_SP           232
#define TF_FP           240
#define TF_RA           248
#define TF_STATUS       256
#define TF_CAUSE        264
#define TF_EPC          272
#define TF_BADVADDR     280
#define TF_HI           288
#define TF_LO           296
#define TF_SIZE         304

#endif /* _MIPS_DEFS_H */
