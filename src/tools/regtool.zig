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

const std = @import("std");
const registry = @import("../registry/registry.zig");
const io = @import("../io/io.zig");
const ob = @import("../ob/object.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "query")) {
        if (args.len < 3) {
            std.debug.print("Usage: reg query <key_path>\n", .{});
            return;
        }
        const path = args[2];
        try queryKey(path);
    } else if (std.mem.eql(u8, command, "add")) {
        if (args.len < 6) {
            std.debug.print("Usage: reg add <key_path> /v <value_name> /t <type> /d <data>\n", .{});
            std.debug.print("Supported types: REG_SZ, REG_DWORD\n", .{});
            return;
        }
        const path = args[2];
        const value_name = args[4];
        const value_type = args[6];
        const value_data = args[8];
        try addValue(path, value_name, value_type, value_data);
    } else if (std.mem.eql(u8, command, "delete")) {
        if (args.len < 4) {
            std.debug.print("Usage: reg delete <key_path> /v <value_name>\n", .{});
            return;
        }
        const path = args[2];
        const value_name = args[4];
        try deleteValue(path, value_name);
    } else if (std.mem.eql(u8, command, "list")) {
        if (args.len < 3) {
            std.debug.print("Usage: reg list <key_path>\n", .{});
            return;
        }
        const path = args[2];
        try listKey(path);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
        return;
    }
}

fn printUsage() void {
    std.debug.print("Registry Command Line Tool for ZirconOS Aero\n", .{});
    std.debug.print("Usage: reg <command> [options]\n", .{});
    std.debug.print("Commands:\n", .{});
    std.debug.print("  query <key_path>                      Query key information\n", .{});
    std.debug.print("  add <key_path> /v <value_name> /t <type> /d <data>  Add/modify key value\n", .{});
    std.debug.print("  delete <key_path> /v <value_name>     Delete key value\n", .{});
    std.debug.print("  list <key_path>                       List all subkeys and values under key\n", .{});
}

fn queryKey(path: []const u8) !void {
    const key_idx = registry.openKeyByNtPath(path) orelse {
        std.debug.print("Error: Key not found: {s}\n", .{path});
        return error.KeyNotFound;
    };

    const key = registry.getKeyByIndex(key_idx) orelse {
        std.debug.print("Error: Invalid key index\n", .{});
        return error.InvalidKey;
    };

    std.debug.print("\nHKEY: {s}\n", .{key.name});
    std.debug.print("Subkeys: {d}\n", .{key.subkey_count});
    std.debug.print("Values: {d}\n", .{key.value_count});
    std.debug.print("Last modified: - (Not implemented)\n\n", .{});
}

fn addValue(path: []const u8, value_name: []const u8, value_type_str: []const u8, value_data: []const u8) !void {
    const key_idx = registry.openKeyByNtPath(path) orelse {
        std.debug.print("Error: Key not found: {s}\n", .{path});
        return error.KeyNotFound;
    };

    if (std.mem.eql(u8, value_type_str, "REG_SZ")) {
        if (!registry.setValueSz(key_idx, value_name, value_data)) {
            std.debug.print("Error: Failed to set REG_SZ value\n", .{});
            return error.SetValueFailed;
        }
        std.debug.print("Success: REG_SZ value {s} set to \"{s}\"\n", .{ value_name, value_data });
    } else if (std.mem.eql(u8, value_type_str, "REG_DWORD")) {
        const dword = std.fmt.parseInt(u32, value_data, 0) catch {
            std.debug.print("Error: Invalid DWORD value: {s}\n", .{value_data});
            return error.InvalidValue;
        };
        if (!registry.setValueDword(key_idx, value_name, dword)) {
            std.debug.print("Error: Failed to set REG_DWORD value\n", .{});
            return error.SetValueFailed;
        }
        std.debug.print("Success: REG_DWORD value {s} set to {d} (0x{x})\n", .{ value_name, dword, dword });
    } else {
        std.debug.print("Error: Unsupported value type: {s}\n", .{value_type_str});
        return error.UnsupportedType;
    }
}

fn deleteValue(path: []const u8, value_name: []const u8) !void {
    const key_idx = registry.openKeyByNtPath(path) orelse {
        std.debug.print("Error: Key not found: {s}\n", .{path});
        return error.KeyNotFound;
    };

    if (!registry.deleteValue(key_idx, value_name)) {
        std.debug.print("Error: Failed to delete value {s}\n", .{value_name});
        return error.DeleteFailed;
    }
    std.debug.print("Success: Value {s} deleted\n", .{value_name});
}

fn listKey(path: []const u8) !void {
    const key_idx = registry.openKeyByNtPath(path) orelse {
        std.debug.print("Error: Key not found: {s}\n", .{path});
        return error.KeyNotFound;
    };

    _ = registry.getKeyByIndex(key_idx) orelse {
        std.debug.print("Error: Invalid key index\n", .{});
        return error.InvalidKey;
    };

    std.debug.print("\nListing contents of {s}:\n", .{path});

    std.debug.print("\n[Subkeys]\n", .{});
    var iter = registry.getSubkeyIterator(key_idx);
    while (registry.nextSubkey(&iter)) |subkey| {
        std.debug.print("  {s}\n", .{subkey.name});
    }

    std.debug.print("\n[Values]\n", .{});
    var value_iter = registry.getValueIterator(key_idx);
    while (registry.nextValue(&value_iter)) |value| {
        switch (value.value_type) {
            .REG_SZ => {
                const data_str = @as([*:0]const u8, @ptrCast(value.data));
                std.debug.print("  {s}    REG_SZ    \"{s}\"\n", .{ value.name, data_str });
            },
            .REG_DWORD => {
                const dword_val = @as(*const u32, @ptrCast(value.data)).*;
                std.debug.print("  {s}    REG_DWORD    {d} (0x{x})\n", .{ value.name, dword_val, dword_val });
            },
            else => {
                std.debug.print("  {s}    <UNSUPPORTED_TYPE>\n", .{value.name});
            },
        }
    }
    std.debug.print("\n", .{});
}
