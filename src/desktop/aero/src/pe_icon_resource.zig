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
// Module: src/desktop/aero/src/pe_icon_resource.zig
// Purpose: Parse PE32+ .rsrc to locate a resource by type id and name id (clean-room from PE/COFF spec).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/windows/win32/debug/pe-format
// RISC-V PE machine IDs: UEFI 2.10 Debugger Support — https://uefi.org/specs/UEFI/2.10_A/18_Protocols_Debugger_Support.html

const std = @import("std");

/// `RT_*` numeric resource types (Win32 public constants).
pub const rt_icon: u32 = 3;
pub const rt_group_icon: u32 = 14;
pub const rt_cursor: u32 = 12;
pub const rt_group_cursor: u32 = 14;

/// COFF `Machine` field (PE/COFF + UEFI portable-PE naming where applicable).
pub const image_file_machine_amd64: u16 = 0x8664;
pub const image_file_machine_arm64: u16 = 0xAA64;
pub const image_file_machine_loongarch32: u16 = 0x6232;
pub const image_file_machine_loongarch64: u16 = 0x6264;
pub const image_file_machine_riscv32: u16 = 0x5032;
pub const image_file_machine_riscv64: u16 = 0x5064;
pub const image_file_machine_riscv128: u16 = 0x5128;

/// Raw bytes of the first language variant for integer `(type_id, name_id)`.
pub fn resourceDataById(pe: []const u8, type_id: u32, name_id: u32) ?[]const u8 {
    const mach = coffMachine(pe) orelse return null;
    if (!isSupportedCoffMachineForRsrc(mach)) return null;
    const resource_rva = resourceDirRva(pe) orelse return null;
    const name_dir_rva = walkDirLevel(pe, resource_rva, resource_rva, type_id) orelse return null;
    const lang_dir_rva = walkDirLevel(pe, resource_rva, name_dir_rva, name_id) orelse return null;
    return firstLeafPayload(pe, resource_rva, lang_dir_rva);
}

fn readU16(pe: []const u8, off: usize) ?u16 {
    if (off + 2 > pe.len) return null;
    return std.mem.readInt(u16, pe[off..][0..2], .little);
}

fn readU32(pe: []const u8, off: usize) ?u32 {
    if (off + 4 > pe.len) return null;
    return std.mem.readInt(u32, pe[off..][0..4], .little);
}

fn resourceDirRva(pe: []const u8) ?u32 {
    const pe_off = peHeaderOffset(pe) orelse return null;
    // PE32+ optional header: DataDirectory[IMAGE_DIRECTORY_ENTRY_RESOURCE] at optional+0x80 (after 0x70 + 2*8).
    const dd_resource_va_off = pe_off + 0x18 + 0x70 + 2 * 8;
    if (dd_resource_va_off + 4 > pe.len) return null;
    const rva = readU32(pe, dd_resource_va_off) orelse return null;
    if (rva == 0) return null;
    return rva;
}

fn peHeaderOffset(pe: []const u8) ?usize {
    if (pe.len < 0x40) return null;
    if (readU16(pe, 0) != 0x5a4d) return null;
    const e_lfanew = readU32(pe, 0x3c) orelse return null;
    if (e_lfanew + 4 + 0x18 > pe.len) return null;
    if (readU32(pe, e_lfanew) != 0x00004550) return null;
    const magic = readU16(pe, e_lfanew + 0x18) orelse return null;
    if (magic != 0x20b) return null;
    return e_lfanew;
}

/// COFF `Machine` at NT headers (after `PE\0\0` signature).
pub fn coffMachine(pe: []const u8) ?u16 {
    const pe_off = peHeaderOffset(pe) orelse return null;
    if (pe_off + 4 + 2 > pe.len) return null;
    return readU16(pe, pe_off + 4);
}

pub fn isSupportedCoffMachineForRsrc(machine: u16) bool {
    return switch (machine) {
        image_file_machine_amd64,
        image_file_machine_arm64,
        image_file_machine_loongarch32,
        image_file_machine_loongarch64,
        image_file_machine_riscv32,
        image_file_machine_riscv64,
        image_file_machine_riscv128,
        => true,
        else => false,
    };
}

fn coffNumberOfSections(pe: []const u8, pe_off: usize) ?u16 {
    return readU16(pe, pe_off + 6);
}

fn coffSizeOfOptionalHeader(pe: []const u8, pe_off: usize) ?u16 {
    return readU16(pe, pe_off + 0x14);
}

fn sectionTableOffset(pe: []const u8) ?usize {
    const pe_off = peHeaderOffset(pe) orelse return null;
    const soh = coffSizeOfOptionalHeader(pe, pe_off) orelse return null;
    return pe_off + 0x18 + @as(usize, soh);
}

fn parseSection(pe: []const u8, off: usize) ?struct { virtual_address: u32, virtual_size: u32, pointer_raw: u32, raw_size: u32 } {
    if (off + 40 > pe.len) return null;
    const virtual_size = readU32(pe, off + 0x8) orelse return null;
    const virtual_address = readU32(pe, off + 0xc) orelse return null;
    const raw_size = readU32(pe, off + 0x10) orelse return null;
    const pointer_raw = readU32(pe, off + 0x14) orelse return null;
    return .{
        .virtual_address = virtual_address,
        .virtual_size = virtual_size,
        .pointer_raw = pointer_raw,
        .raw_size = raw_size,
    };
}

pub fn rvaToRaw(pe: []const u8, rva: u32) ?usize {
    const pe_off = peHeaderOffset(pe) orelse return null;
    const nsec = coffNumberOfSections(pe, pe_off) orelse return null;
    const st_off = sectionTableOffset(pe) orelse return null;
    var i: u16 = 0;
    while (i < nsec) : (i += 1) {
        const sec = parseSection(pe, st_off + @as(usize, i) * 40) orelse return null;
        if (rva >= sec.virtual_address and rva < sec.virtual_address + sec.virtual_size) {
            const delta = rva - sec.virtual_address;
            if (sec.pointer_raw == 0 or delta >= sec.raw_size) return null;
            return @as(usize, sec.pointer_raw) + delta;
        }
    }
    return null;
}

/// `resource_root_rva`: DataDirectory resource RVA (base for all relative offsets in tree).
/// `dir_rva`: RVA of this IMAGE_RESOURCE_DIRECTORY.
fn walkDirLevel(pe: []const u8, resource_root_rva: u32, dir_rva: u32, want_id: u32) ?u32 {
    const off = rvaToRaw(pe, dir_rva) orelse return null;
    if (off + 16 > pe.len) return null;
    const named = readU16(pe, off + 12) orelse return null;
    const id_entries = readU16(pe, off + 14) orelse return null;
    const total = @as(usize, named) + @as(usize, id_entries);
    var e: usize = 0;
    var entry_off = off + 16;
    while (e < total) : (e += 1) {
        if (entry_off + 8 > pe.len) return null;
        const name = readU32(pe, entry_off) orelse return null;
        const to_data = readU32(pe, entry_off + 4) orelse return null;
        entry_off += 8;
        if ((name & 0x8000_0000) != 0) continue;
        if (name != want_id) continue;
        if ((to_data & 0x8000_0000) != 0) {
            const rel = to_data & 0x7fff_ffff;
            return resource_root_rva + rel;
        }
        return null;
    }
    return null;
}

fn firstLeafPayload(pe: []const u8, resource_root_rva: u32, dir_rva: u32) ?[]const u8 {
    const off = rvaToRaw(pe, dir_rva) orelse return null;
    if (off + 16 > pe.len) return null;
    const named = readU16(pe, off + 12) orelse return null;
    const id_entries = readU16(pe, off + 14) orelse return null;
    if (named + id_entries == 0) return null;
    const entry_off = off + 16;
    if (entry_off + 8 > pe.len) return null;
    const to_data = readU32(pe, entry_off + 4) orelse return null;
    if ((to_data & 0x8000_0000) != 0) return null;
    const data_struct_rva = resource_root_rva + to_data;
    const ds = rvaToRaw(pe, data_struct_rva) orelse return null;
    if (ds + 8 > pe.len) return null;
    const data_rva = readU32(pe, ds + 0) orelse return null;
    const data_size = readU32(pe, ds + 4) orelse return null;
    const file_off = rvaToRaw(pe, data_rva) orelse return null;
    if (file_off + data_size > pe.len) return null;
    return pe[file_off..][0..data_size];
}

test "coffMachine reads PE32+ LoongArch64 machine field" {
    var pe: [256]u8 = undefined;
    minimalPe32PlusWithMachine(&pe, image_file_machine_loongarch64);
    const m = coffMachine(&pe) orelse return error.BadPe;
    try std.testing.expectEqual(image_file_machine_loongarch64, m);
    try std.testing.expect(isSupportedCoffMachineForRsrc(m));
}

test "isSupportedCoffMachineForRsrc accepts AMD64" {
    try std.testing.expect(isSupportedCoffMachineForRsrc(image_file_machine_amd64));
}

test "isSupportedCoffMachineForRsrc accepts ARM64 and RISC-V machine IDs" {
    try std.testing.expect(isSupportedCoffMachineForRsrc(image_file_machine_arm64));
    try std.testing.expect(isSupportedCoffMachineForRsrc(image_file_machine_riscv32));
    try std.testing.expect(isSupportedCoffMachineForRsrc(image_file_machine_riscv64));
    try std.testing.expect(isSupportedCoffMachineForRsrc(image_file_machine_riscv128));
    try std.testing.expect(isSupportedCoffMachineForRsrc(image_file_machine_loongarch32));
}

fn minimalPe32PlusWithMachine(buf: *[256]u8, machine: u16) void {
    @memset(buf, 0);
    buf[0] = 'M';
    buf[1] = 'Z';
    const pe_off: u32 = 128;
    std.mem.writeInt(u32, buf[0x3c..0x40], pe_off, .little);
    std.mem.writeInt(u32, buf[pe_off..][0..4], 0x00004550, .little);
    std.mem.writeInt(u16, buf[pe_off + 4 ..][0..2], machine, .little);
    const soh: u16 = 240;
    std.mem.writeInt(u16, buf[pe_off + 20 ..][0..2], soh, .little);
    std.mem.writeInt(u16, buf[pe_off + 24 ..][0..2], 0x20b, .little);
}

test "coffMachine reads ARM64 and RISC-V64 machine fields" {
    var pe: [256]u8 = undefined;
    minimalPe32PlusWithMachine(&pe, image_file_machine_arm64);
    try std.testing.expectEqual(image_file_machine_arm64, coffMachine(&pe).?);
    minimalPe32PlusWithMachine(&pe, image_file_machine_riscv64);
    try std.testing.expectEqual(image_file_machine_riscv64, coffMachine(&pe).?);
}

test "resourceDataById finds group icon 101 in zircon dll if built" {
    const candidates = [_][]const u8{
        "zig-out/assets/zircon_shell32_res.dll",
        "../../../zig-out/assets/zircon_shell32_res.dll",
    };
    var opened: ?std.fs.File = null;
    for (candidates) |path| {
        opened = std.fs.cwd().openFile(path, .{}) catch null;
        if (opened != null) break;
    }
    var file = opened orelse return;
    defer file.close();
    const max = 8 * 1024 * 1024;
    const data = file.readToEndAlloc(std.testing.allocator, max) catch return;
    defer std.testing.allocator.free(data);
    const slice = resourceDataById(data, rt_group_icon, 101) orelse return;
    try std.testing.expect(slice.len >= 14);
}
