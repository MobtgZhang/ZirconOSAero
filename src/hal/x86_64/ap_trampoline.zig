// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/ap_trampoline.zig
// Purpose: 将实模式 AP（SIPI 向量页）经 16→32→64 位过渡写入物理跳板页；与 Intel SDM Vol.3（CR0/CR4/EFER、LGDT、远跳）及 ACPI MADT 启动行为描述一致。
//
// This is an independent clean-room implementation.
// Reference: Intel SDM Vol.3 Ch.9–10; ACPI MADT (processor startup).

const std = @import("std");

/// 跳板页内布局（相对于页基址，默认物理 0x8000）。
pub const off_gdt: usize = 0x40;
pub const off_gdtr: usize = 0x60;
pub const off_prot32: usize = 0x200;
pub const off_long64: usize = 0x280;
pub const off_patch_cr3: usize = 0x100;
pub const off_patch_entry: usize = 0x108;

/// 在 `page_phys`（须已 identity 映射且可写）写入可执行跳板并打补丁。
///
/// **unsafe**：调用方保证 `page_phys` 为有效 RAM、`cr3_phys` 含对该页及内核映像的恒等映射。
pub fn writeTrampolinePage(page_phys: usize, cr3_phys: u32, entry_rip: u64) void {
    const d: [*]align(1) u8 = @ptrFromInt(page_phys);
    @memset(d[0..4096], 0);

    writeU32(d, off_patch_cr3, cr3_phys);
    writeU64(d, off_patch_entry, entry_rip);

    // GDT: null, 32-bit code 0x08, 32-bit data 0x10, 64-bit code 0x18
    const gdt_base: u32 = @truncate(page_phys + off_gdt);
    writeU64(d, off_gdt + 0, 0);
    writeU64(d, off_gdt + 8, 0x00CF9A000000FFFF);
    writeU64(d, off_gdt + 16, 0x00CF92000000FFFF);
    writeU64(d, off_gdt + 24, 0x00AF9A000000FFFF);

    // GDTR
    writeU16(d, off_gdtr + 0, 31); // 4 entries * 8 - 1
    writeU32(d, off_gdtr + 2, gdt_base);

    const prot_linear: u32 = @truncate(page_phys + off_prot32);

    // --- real mode @ offset 0 ---
    var o: usize = 0;
    d[o] = 0xFA; // cli
    o += 1;
    d[o + 0] = 0x31;
    d[o + 1] = 0xC0; // xor ax, ax
    o += 2;
    d[o + 0] = 0x8E;
    d[o + 1] = 0xD8; // mov ds, ax
    d[o + 2] = 0x8E;
    d[o + 3] = 0xC0; // mov es, ax
    d[o + 4] = 0x8E;
    d[o + 5] = 0xD0; // mov ss, ax
    o += 6;
    d[o + 0] = 0xBC;
    d[o + 1] = 0x00;
    d[o + 2] = 0x8F; // mov sp, 0x8F00
    o += 3;
    d[o + 0] = 0x0F;
    d[o + 1] = 0x01;
    d[o + 2] = 0x16; // lgdt [disp16]
    d[o + 3] = @truncate(off_gdtr);
    d[o + 4] = @truncate(off_gdtr >> 8);
    o += 5;
    d[o + 0] = 0x0F;
    d[o + 1] = 0x20;
    d[o + 2] = 0xC0; // mov eax, cr0
    d[o + 3] = 0x83;
    d[o + 4] = 0xC8;
    d[o + 5] = 0x01; // or eax, 1
    d[o + 6] = 0x0F;
    d[o + 7] = 0x22;
    d[o + 8] = 0xC0; // mov cr0, eax
    o += 9;
    d[o + 0] = 0x66;
    d[o + 1] = 0xEA; // ljmpl
    writeU32(d, o + 2, prot_linear);
    d[o + 6] = 0x08;
    d[o + 7] = 0x00;
    o += 8;

    // --- protected 32-bit @ off_prot32 ---
    o = off_prot32;
    d[o + 0] = 0x66;
    d[o + 1] = 0xB8;
    d[o + 2] = 0x10;
    d[o + 3] = 0x00; // mov ax, 0x10
    o += 4;
    const seg_movs = [_]u8{ 0x8E, 0xD8, 0x8E, 0xC0, 0x8E, 0xE0, 0x8E, 0xE8, 0x8E, 0xD0 };
    @memcpy(d[o .. o + seg_movs.len], &seg_movs);
    o += seg_movs.len;
    d[o + 0] = 0xA1; // mov eax, moffs32
    writeU32(d, o + 1, @truncate(page_phys + off_patch_cr3));
    o += 5;
    d[o + 0] = 0x0F;
    d[o + 1] = 0x22;
    d[o + 2] = 0xD8; // mov cr3, eax
    o += 3;
    // PAE + OSFXSR 须在 EFER.LME 之前（Intel SDM 启用长模式顺序）
    d[o + 0] = 0x0F;
    d[o + 1] = 0x20;
    d[o + 2] = 0xE0; // mov eax, cr4
    o += 3;
    d[o + 0] = 0x0D;
    writeU32(d, o + 1, (1 << 5) | (1 << 9)); // or eax, PAE|OSXSAVE
    o += 5;
    d[o + 0] = 0x0F;
    d[o + 1] = 0x22;
    d[o + 2] = 0xE0; // mov cr4, eax
    o += 3;
    d[o + 0] = 0xB9;
    writeU32(d, o + 1, 0xC0000080); // mov ecx, IA32_EFER
    o += 5;
    d[o + 0] = 0x0F;
    d[o + 1] = 0x32; // rdmsr
    o += 2;
    d[o + 0] = 0x0D;
    writeU32(d, o + 1, 1 << 8); // or eax, LME
    o += 5;
    d[o + 0] = 0x31;
    d[o + 1] = 0xD2; // xor edx, edx — EFER 高 32 位为 0
    o += 2;
    d[o + 0] = 0x0F;
    d[o + 1] = 0x30; // wrmsr
    o += 2;
    d[o + 0] = 0x0F;
    d[o + 1] = 0x20;
    d[o + 2] = 0xC0; // mov eax, cr0
    o += 3;
    d[o + 0] = 0x0D;
    writeU32(d, o + 1, 1 << 31); // or eax, PG
    o += 5;
    d[o + 0] = 0x0F;
    d[o + 1] = 0x22;
    d[o + 2] = 0xC0; // mov cr0, eax
    o += 3;
    const long_linear: u32 = @truncate(page_phys + off_long64);
    d[o + 0] = 0xEA; // ljmpl
    writeU32(d, o + 1, long_linear);
    d[o + 5] = 0x18;
    d[o + 6] = 0x00;
    o += 7;

    // --- long mode @ off_long64 ---
    o = off_long64;
    d[o + 0] = 0x66;
    d[o + 1] = 0xB8;
    d[o + 2] = 0x10;
    d[o + 3] = 0x00;
    o += 4;
    @memcpy(d[o .. o + seg_movs.len], &seg_movs);
    o += seg_movs.len;
    const rip_next = page_phys + o + 7;
    const disp: i32 = @intCast((page_phys + off_patch_entry) -% rip_next);
    d[o + 0] = 0x48;
    d[o + 1] = 0x8B;
    d[o + 2] = 0x05; // mov rax, [rip+disp32]
    writeU32(d, o + 3, @bitCast(disp));
    o += 7;
    d[o + 0] = 0xFF;
    d[o + 1] = 0xE0; // jmp rax
}

fn writeU16(d: [*]align(1) u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, d[off..][0..2], v, .little);
}

fn writeU32(d: [*]align(1) u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, d[off..][0..4], v, .little);
}

fn writeU64(d: [*]align(1) u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, d[off..][0..8], v, .little);
}
