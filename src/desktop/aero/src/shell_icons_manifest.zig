// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/aero/src/shell_icons_manifest.zig
// Purpose: Minimal parsing of `zircon_shell32_res.manifest.json` `binary_form` (LoongArch bundle vs future PE).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.

const std = @import("std");

pub const ShellBinaryForm = enum {
    ico_bundle,
    pe_rsrc,
    unknown,
};

fn skipWs(i: *usize, json: []const u8) void {
    while (i.* < json.len) : (i.* += 1) {
        switch (json[i.*]) {
            ' ', '\t', '\n', '\r' => continue,
            else => return,
        }
    }
}

/// Reads `"binary_form": "<value>"` without a full JSON dependency.
pub fn parseBinaryForm(json: []const u8) ShellBinaryForm {
    const needle = "\"binary_form\"";
    const idx = std.mem.indexOf(u8, json, needle) orelse return .unknown;
    var i: usize = idx + needle.len;
    skipWs(&i, json);
    if (i >= json.len or json[i] != ':') return .unknown;
    i += 1;
    skipWs(&i, json);
    if (i >= json.len or json[i] != '"') return .unknown;
    i += 1;
    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {}
    if (i >= json.len) return .unknown;
    const val = json[start..i];
    if (std.mem.eql(u8, val, "ico_bundle")) return .ico_bundle;
    if (std.mem.eql(u8, val, "pe_rsrc")) return .pe_rsrc;
    if (std.mem.eql(u8, val, "pe")) return .pe_rsrc;
    return .unknown;
}

test "parseBinaryForm ico_bundle" {
    const j =
        \\{ "schema_version": 1, "binary_form": "ico_bundle", "icons": [] }
    ;
    try std.testing.expectEqual(ShellBinaryForm.ico_bundle, parseBinaryForm(j));
}

test "parseBinaryForm pe_rsrc" {
    try std.testing.expectEqual(ShellBinaryForm.pe_rsrc, parseBinaryForm(
        \\{"binary_form":"pe_rsrc"}
    ));
}

test "parseBinaryForm unknown when missing" {
    try std.testing.expectEqual(ShellBinaryForm.unknown, parseBinaryForm("{}"));
}
