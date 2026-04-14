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
// Module: src/subsystems/win32k/atoms.zig
// Purpose: 全局 ATOM 表占位（未来 `NtAddAtom` / `NtFindAtom` 与 user32 对齐）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/winmsg/about-atom-tables

const std = @import("std");

const max_atoms: usize = 64;

var names: [max_atoms][32]u8 = undefined;
var name_lens: [max_atoms]u8 = undefined;
var atom_count: usize = 0;
var next_atom: u16 = 0xC000;

/// 注册字符串并返回 ATOM（0xC000 起为应用全局原子范围占位）。
pub fn addGlobalAtom(name: []const u8) ?u16 {
    if (atom_count >= max_atoms) return null;
    const n = @min(name.len, 32);
    const idx = atom_count;
    @memcpy(names[idx][0..n], name[0..n]);
    name_lens[idx] = @intCast(n);
    atom_count += 1;
    const a = next_atom;
    next_atom +%= 1;
    return a;
}

pub fn resetForTest() void {
    atom_count = 0;
    next_atom = 0xC000;
}

test "global atom monotonic" {
    resetForTest();
    const a1 = addGlobalAtom("TEST") orelse {
        try std.testing.expect(false);
        return;
    };
    const a2 = addGlobalAtom("OTHER") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(a2 > a1);
}
