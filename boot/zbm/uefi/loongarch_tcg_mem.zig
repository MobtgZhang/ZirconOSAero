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

//! QEMU 10.x `qemu-system-loongarch64` 的 TCG 对部分 LLVM 变址访存（`ldx.bu` / `ldx.d`）及少数位操作指令支持不完整，
//! UEFI 下 ZBM 会在菜单绘制或后续路径上 #INE。非 LoongArch 目标在编译期走普通 `[]` 访问，无额外开销。
const builtin = @import("builtin");

/// 以 `add.d` + `ld.bu` 代替 `(ptr + i)[0]`，避免生成 `ldx.bu`。
pub fn storeU8(ptr: [*]u8, i: usize, v: u8) void {
    if (builtin.cpu.arch != .loongarch64) {
        ptr[i] = v;
        return;
    }
    var tmp: usize = undefined;
    asm volatile ("add.d %[t], %[b], %[i]\n\tst.b %[v], %[t], 0"
        : [t] "=&r" (tmp),
        : [b] "r" (@intFromPtr(ptr)),
          [i] "r" (i),
          [v] "r" (v),
    );
}

/// 避免 `@memcpy` 在 LoongArch 上生成 **`ldx.bu`/`stx.bu`**（部分 QEMU TCG 未实现）。
pub fn copyBytes(dst: [*]u8, src: [*]const u8, len: usize) void {
    if (builtin.cpu.arch != .loongarch64) {
        @memcpy(dst[0..len], src[0..len]);
        return;
    }
    var i: usize = 0;
    while (i < len) : (i += 1) {
        storeU8(dst, i, loadU8(src, i));
    }
}

pub fn setBytes(dst: [*]u8, len: usize, val: u8) void {
    if (builtin.cpu.arch != .loongarch64) {
        @memset(dst[0..len], val);
        return;
    }
    var i: usize = 0;
    while (i < len) : (i += 1) storeU8(dst, i, val);
}

pub fn loadU8(ptr: [*]const u8, i: usize) u8 {
    if (builtin.cpu.arch != .loongarch64) return ptr[i];
    var tmp: usize = undefined;
    return asm ("add.d %[t], %[b], %[i]\n\tld.bu %[o], %[t], 0"
        : [o] "=r" (-> u8),
          [t] "=&r" (tmp),
        : [b] "r" (@intFromPtr(ptr)),
          [i] "r" (i),
    );
}

/// 从绝对地址写 u8（`st.b`）；与 `loadU8Abs` 配对，用于 `bool` / GOP 字节字段。
pub noinline fn storeU8Abs(addr: usize, v: u8) void {
    if (builtin.cpu.arch != .loongarch64) {
        @as(*align(1) u8, @ptrFromInt(addr)).* = v;
        return;
    }
    asm volatile ("st.b %[v], %[a], 0"
        :
        : [a] "r" (addr),
          [v] "r" (v),
    );
}

/// 从绝对地址读 u32（`ld.w rj,0`）。
pub noinline fn loadU32Abs(addr: usize) u32 {
    if (builtin.cpu.arch != .loongarch64) {
        return @as(*align(1) const u32, @ptrFromInt(addr)).*;
    }
    return asm ("ld.w %[o], %[a], 0"
        : [o] "=r" (-> u32),
        : [a] "r" (addr),
    );
}

/// 单字节绝对加载，避免 `(base+off)[0]` 被折叠为 **`ldx.bu`**（部分 QEMU LoongArch TCG #INE）。
pub noinline fn loadU8Abs(addr: usize) u8 {
    if (builtin.cpu.arch != .loongarch64) {
        return @as(*align(1) const u8, @ptrFromInt(addr)).*;
    }
    return asm ("ld.bu %[o], %[a], 0"
        : [o] "=r" (-> u8),
        : [a] "r" (addr),
    );
}

/// 从绝对地址读 u64（`ld.d rj,0`），避免基址+索引折叠为 `ldx.d`。
pub noinline fn loadU64Abs(addr: usize) u64 {
    if (builtin.cpu.arch != .loongarch64) {
        return @as(*align(1) const u64, @ptrFromInt(addr)).*;
    }
    return asm ("ld.d %[o], %[a], 0"
        : [o] "=r" (-> u64),
        : [a] "r" (addr),
    );
}

/// 向绝对地址写 u32（`st.w`），避免对 `extern` 结构体字段成组写入时 LLVM 生成 **`ldx.w`** 跳转表路径。
pub noinline fn storeU32Abs(addr: usize, v: u32) void {
    if (builtin.cpu.arch != .loongarch64) {
        @as(*align(1) u32, @ptrFromInt(addr)).* = v;
        return;
    }
    asm volatile ("st.w %[v], %[a], 0"
        :
        : [a] "r" (addr),
          [v] "r" (v),
    );
}

pub noinline fn storeU64Abs(addr: usize, v: u64) void {
    if (builtin.cpu.arch != .loongarch64) {
        @as(*align(1) u64, @ptrFromInt(addr)).* = v;
        return;
    }
    asm volatile ("st.d %[v], %[a], 0"
        :
        : [a] "r" (addr),
          [v] "r" (v),
    );
}

/// 读取 Zig `[]const u8` 在内存中的 ptr+len 对（各 8 字节）。
pub fn sliceFromRawParts(desc_base: usize) []const u8 {
    const p = loadU64Abs(desc_base);
    const l = loadU64Abs(desc_base +% 8);
    return @as([*]const u8, @ptrFromInt(p))[0..l];
}
