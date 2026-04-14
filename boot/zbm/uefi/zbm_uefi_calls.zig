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

//! LoongArch QEMU TCG：Zig 对 `uefi.Status` 的多路 `switch` 常生成 **`ldx.d` 跳转表**，会 #INE。
//! 本文件在 LoongArch 上改为比较 `@intFromEnum(status)` 与 `success`，并直接调用 `_*` 函数指针。
const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;

fn statusOk(st: uefi.Status) bool {
    return @intFromEnum(st) == @intFromEnum(uefi.Status.success);
}

pub fn locateSimpleTextInputEx(bs: *uefi.tables.BootServices) ?*uefi.protocol.SimpleTextInputEx {
    if (builtin.cpu.arch != .loongarch64) {
        return bs.locateProtocol(uefi.protocol.SimpleTextInputEx, null) catch null;
    }
    var iface: *uefi.protocol.SimpleTextInputEx = undefined;
    const st = bs._locateProtocol(
        &uefi.protocol.SimpleTextInputEx.guid,
        null,
        @ptrCast(&iface),
    );
    if (statusOk(st)) return iface;
    return null;
}

pub fn stallMicroseconds(bs: *uefi.tables.BootServices, micros: usize) void {
    if (builtin.cpu.arch != .loongarch64) {
        bs.stall(micros) catch {};
        return;
    }
    _ = bs._stall(micros);
}

pub fn checkEventSignaled(bs: *uefi.tables.BootServices, event: uefi.Event) bool {
    if (builtin.cpu.arch != .loongarch64) {
        return bs.checkEvent(event) catch false;
    }
    return statusOk(bs._checkEvent(event));
}

/// 与原先 `waitForEvent(...) catch stall(10_000)` 语义一致。
pub fn waitForEventWithStallFallback(bs: *uefi.tables.BootServices, events: []const uefi.Event) void {
    if (builtin.cpu.arch != .loongarch64) {
        _ = bs.waitForEvent(events) catch {
            bs.stall(10_000) catch {};
        };
        return;
    }
    var idx: usize = undefined;
    const st = bs._waitForEvent(events.len, events.ptr, &idx);
    if (!statusOk(st)) {
        _ = bs._stall(10_000);
    }
}

pub fn readKeyStrokeSimple(cin: *uefi.protocol.SimpleTextInput) ?uefi.protocol.SimpleTextInput.Key.Input {
    if (builtin.cpu.arch != .loongarch64) {
        return cin.readKeyStroke() catch null;
    }
    var key: uefi.protocol.SimpleTextInput.Key.Input = undefined;
    const st = cin._read_key_stroke(cin, &key);
    if (statusOk(st)) return key;
    return null;
}

pub fn locateGraphicsOutput(bs: *uefi.tables.BootServices) ?*uefi.protocol.GraphicsOutput {
    if (builtin.cpu.arch != .loongarch64) {
        return bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch null;
    }
    var iface: *uefi.protocol.GraphicsOutput = undefined;
    const st = bs._locateProtocol(&uefi.protocol.GraphicsOutput.guid, null, @ptrCast(&iface));
    if (!statusOk(st)) return null;
    return iface;
}

pub fn getMemoryMapThin(
    self: *const uefi.tables.BootServices,
    buffer: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8,
) ?uefi.tables.MemoryMapSlice {
    if (builtin.cpu.arch != .loongarch64) {
        return self.getMemoryMap(buffer) catch null;
    }
    var info: uefi.tables.MemoryMapInfo = undefined;
    info.len = buffer.len;
    const st = self._getMemoryMap(&info.len, buffer.ptr, &info.key, &info.descriptor_size, &info.descriptor_version);
    if (!statusOk(st)) return null;
    info.len = @divExact(info.len, info.descriptor_size);
    return .{ .info = info, .ptr = buffer.ptr };
}

pub fn getMemoryMapInfoThin(self: *const uefi.tables.BootServices) ?uefi.tables.MemoryMapInfo {
    if (builtin.cpu.arch != .loongarch64) {
        return self.getMemoryMapInfo() catch null;
    }
    var info: uefi.tables.MemoryMapInfo = undefined;
    info.len = 0;
    const st = self._getMemoryMap(&info.len, null, &info.key, &info.descriptor_size, &info.descriptor_version);
    const sv = @intFromEnum(st);
    if (sv != @intFromEnum(uefi.Status.success) and sv != @intFromEnum(uefi.Status.buffer_too_small)) return null;
    info.len = @divExact(info.len, info.descriptor_size);
    return info;
}

pub fn exitBootServicesThin(
    self: *uefi.tables.BootServices,
    image: uefi.Handle,
    map_key: uefi.tables.MemoryMapKey,
) bool {
    if (builtin.cpu.arch != .loongarch64) {
        self.exitBootServices(image, map_key) catch return false;
        return true;
    }
    const st = self._exitBootServices(image, map_key);
    return statusOk(st);
}

/// 避免 `allocatePages(.{ .address = ... })` 对 `AllocateLocation` 使用 `activeTag` → `ldx.d`。
pub fn allocatePagesAtLoaderThin(
    bs: *uefi.tables.BootServices,
    dest: [*]align(4096) uefi.Page,
    num_pages: usize,
) bool {
    if (builtin.cpu.arch != .loongarch64) {
        bs.allocatePages(.{ .address = dest }, .loader_data, num_pages) catch return false;
        return true;
    }
    var ptr = dest;
    const st = bs._allocatePages(.address, .loader_data, num_pages, &ptr);
    return statusOk(st);
}

pub fn readKeyStrokeEx(ex: *uefi.protocol.SimpleTextInputEx) ?uefi.protocol.SimpleTextInputEx.Key {
    if (builtin.cpu.arch != .loongarch64) {
        if (ex.readKeyStroke()) |k| return k else |_| return null;
    }
    var key: uefi.protocol.SimpleTextInputEx.Key = undefined;
    const st = ex._read_key_stroke_ex(ex, &key);
    if (statusOk(st)) return key;
    return null;
}
