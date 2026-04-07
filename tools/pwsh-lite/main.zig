//! 最小 cmdlet 风格管道宿主（**非** Microsoft PowerShell；名称与行为均为自研子集）。
//! 构建：`zig build pwsh-lite` → `zig-out/bin/pwsh-lite`。
const std = @import("std");

const Obj = struct {
    fields: std.StringArrayHashMapUnmanaged([]const u8) = .{},

    fn init(a: std.mem.Allocator) Obj {
        _ = a;
        return .{};
    }

    fn deinit(self: *Obj, a: std.mem.Allocator) void {
        var it = self.fields.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        self.fields.deinit(a);
    }

    fn put(self: *Obj, a: std.mem.Allocator, k: []const u8, v: []const u8) !void {
        const kk = try a.dupe(u8, k);
        errdefer a.free(kk);
        const vv = try a.dupe(u8, v);
        const gop = try self.fields.getOrPut(a, kk);
        if (gop.found_existing) {
            a.free(gop.key_ptr.*);
            a.free(gop.value_ptr.*);
            gop.key_ptr.* = kk;
            gop.value_ptr.* = vv;
        } else {
            gop.key_ptr.* = kk;
            gop.value_ptr.* = vv;
        }
    }

    fn get(self: *const Obj, key: []const u8) ?[]const u8 {
        return self.fields.get(key);
    }

    fn print(self: *const Obj, w: anytype) !void {
        const keys = self.fields.keys();
        const vals = self.fields.values();
        var i: usize = 0;
        while (i < keys.len) : (i += 1) {
            try w.print("{s}={s}\n", .{ keys[i], vals[i] });
        }
        try w.writeAll("---\n");
    }
};

fn deinitObjects(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(Obj)) void {
    for (list.items) |*o| o.deinit(a);
    list.deinit(a);
}

fn splitPipeline(a: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var parts = std.ArrayListUnmanaged([]const u8){};
    errdefer parts.deinit(a);
    var it = std.mem.splitScalar(u8, line, '|');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t\r\n");
        if (s.len == 0) continue;
        try parts.append(a, s);
    }
    return try parts.toOwnedSlice(a);
}

fn tokenizeSegment(a: std.mem.Allocator, seg: []const u8) ![][]const u8 {
    var toks = std.ArrayListUnmanaged([]const u8){};
    errdefer toks.deinit(a);
    var rest = seg;
    while (rest.len > 0) {
        rest = std.mem.trimLeft(u8, rest, " \t");
        if (rest.len == 0) break;
        if (rest[0] == '"') {
            const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.BadQuote;
            try toks.append(a, rest[1..end]);
            rest = rest[end + 1 ..];
            continue;
        }
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse rest.len;
        const cut = @min(space, tab);
        try toks.append(a, rest[0..cut]);
        rest = rest[cut..];
    }
    return try toks.toOwnedSlice(a);
}

fn stdoutWriter() std.fs.File.DeprecatedWriter {
    return std.fs.File.stdout().deprecatedWriter();
}

fn cmdHelp(w: anytype) !void {
    try w.writeAll(
        \\pwsh-lite — 自研 cmdlet 子集（与 Windows PowerShell 不兼容）
        \\管道：Cmdlet1 | Cmdlet2 | ...
        \\可用：Help Get-Process Get-Item Get-Content Set-Location Get-Location
        \\       Where-Object Select-Object Sort-Object Measure-Object
        \\
    );
}

fn cmdGetProcess(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(Obj)) !void {
    const rows = [_][2][]const u8{
        .{ "Name", "Idle" },     .{ "Id", "0" },
        .{ "Name", "System" },   .{ "Id", "4" },
        .{ "Name", "pwsh-lite" }, .{ "Id", "1" },
    };
    var i: usize = 0;
    while (i < rows.len) : (i += 2) {
        var o = Obj.init(a);
        errdefer o.deinit(a);
        try o.put(a, rows[i][0], rows[i][1]);
        try o.put(a, rows[i + 1][0], rows[i + 1][1]);
        try out.append(a, o);
    }
}

fn cmdGetItem(a: std.mem.Allocator, path: []const u8, out: *std.ArrayListUnmanaged(Obj)) !void {
    std.fs.cwd().access(path, .{}) catch {
        var o = Obj.init(a);
        errdefer o.deinit(a);
        try o.put(a, "Error", "NotFound");
        try o.put(a, "Path", path);
        try out.append(a, o);
        return;
    };
    const base = std.fs.path.basename(path);
    var o = Obj.init(a);
    errdefer o.deinit(a);
    try o.put(a, "Name", base);
    try o.put(a, "FullName", path);
    try out.append(a, o);
}

fn cmdGetContent(a: std.mem.Allocator, path: []const u8, out: *std.ArrayListUnmanaged(Obj)) !void {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const max = 64 * 1024;
    const data = try f.readToEndAlloc(a, max);
    defer a.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |ln| {
        var o = Obj.init(a);
        errdefer o.deinit(a);
        try o.put(a, "Line", ln);
        try out.append(a, o);
    }
}

fn cmdGetLocation(a: std.mem.Allocator, cwd: []const u8, out: *std.ArrayListUnmanaged(Obj)) !void {
    var o = Obj.init(a);
    errdefer o.deinit(a);
    try o.put(a, "Path", cwd);
    try out.append(a, o);
}

fn cmdWhereObject(a: std.mem.Allocator, prop: []const u8, needle: []const u8, in: []const Obj, out: *std.ArrayListUnmanaged(Obj)) !void {
    for (in) |src| {
        if (src.get(prop)) |v| {
            if (std.mem.indexOf(u8, v, needle) != null) {
                var o = Obj.init(a);
                errdefer o.deinit(a);
                var it = src.fields.iterator();
                while (it.next()) |e| {
                    try o.put(a, e.key_ptr.*, e.value_ptr.*);
                }
                try out.append(a, o);
            }
        }
    }
}

fn cmdSelectObject(a: std.mem.Allocator, prop: []const u8, in: []const Obj, out: *std.ArrayListUnmanaged(Obj)) !void {
    for (in) |src| {
        var o = Obj.init(a);
        errdefer o.deinit(a);
        if (src.get(prop)) |v| {
            try o.put(a, prop, v);
        }
        try out.append(a, o);
    }
}

fn cloneObject(a: std.mem.Allocator, src: Obj) !Obj {
    var o = Obj.init(a);
    errdefer o.deinit(a);
    var it = src.fields.iterator();
    while (it.next()) |e| {
        try o.put(a, e.key_ptr.*, e.value_ptr.*);
    }
    return o;
}

fn cmdSortObject(a: std.mem.Allocator, prop: []const u8, in: []const Obj, out: *std.ArrayListUnmanaged(Obj)) !void {
    const owned = try a.alloc(Obj, in.len);
    defer {
        for (owned) |*o| o.deinit(a);
        a.free(owned);
    }
    for (in, 0..) |src, j| {
        owned[j] = try cloneObject(a, src);
    }
    var si: usize = 1;
    while (si < owned.len) : (si += 1) {
        var j = si;
        while (j > 0) {
            const sa = owned[j - 1].get(prop) orelse "";
            const sb = owned[j].get(prop) orelse "";
            if (std.mem.order(u8, sa, sb) != .gt) break;
            std.mem.swap(Obj, &owned[j - 1], &owned[j]);
            j -= 1;
        }
    }
    for (owned) |o| {
        try out.append(a, try cloneObject(a, o));
    }
}

fn cmdMeasureObject(in: []const Obj, w: anytype) !void {
    try w.print("Count={d}\n", .{in.len});
}

fn runSegment(
    a: std.mem.Allocator,
    seg: []const u8,
    cwd: *?[]const u8,
    input: []const Obj,
    out: *std.ArrayListUnmanaged(Obj),
) !void {
    const toks = try tokenizeSegment(a, seg);
    defer a.free(toks);
    if (toks.len == 0) return;
    const verb = toks[0];

    if (std.mem.eql(u8, verb, "Help")) {
        const w = stdoutWriter();
        try cmdHelp(w);
        return;
    }
    if (std.mem.eql(u8, verb, "Get-Process")) {
        try cmdGetProcess(a, out);
        return;
    }
    if (std.mem.eql(u8, verb, "Get-Item")) {
        const p = if (toks.len >= 2) toks[1] else ".";
        try cmdGetItem(a, p, out);
        return;
    }
    if (std.mem.eql(u8, verb, "Get-Content")) {
        if (toks.len < 2) return error.MissingPath;
        try cmdGetContent(a, toks[1], out);
        return;
    }
    if (std.mem.eql(u8, verb, "Set-Location")) {
        if (toks.len < 2) return error.MissingPath;
        var dir = try std.fs.cwd().openDir(toks[1], .{});
        defer dir.close();
        try dir.setAsCwd();
        if (cwd.*) |old| a.free(old);
        cwd.* = try std.fs.cwd().realpathAlloc(a, ".");
        return;
    }
    if (std.mem.eql(u8, verb, "Get-Location")) {
        const c = cwd.* orelse try std.fs.cwd().realpathAlloc(a, ".");
        if (cwd.* == null) cwd.* = c;
        try cmdGetLocation(a, c, out);
        return;
    }
    if (std.mem.eql(u8, verb, "Where-Object")) {
        if (toks.len < 3) return error.BadWhere;
        try cmdWhereObject(a, toks[1], toks[2], input, out);
        return;
    }
    if (std.mem.eql(u8, verb, "Select-Object")) {
        var prop: []const u8 = "Name";
        if (toks.len >= 3 and std.mem.eql(u8, toks[1], "-Property")) {
            prop = toks[2];
        } else if (toks.len >= 2) {
            prop = toks[1];
        }
        try cmdSelectObject(a, prop, input, out);
        return;
    }
    if (std.mem.eql(u8, verb, "Sort-Object")) {
        var prop: []const u8 = "Name";
        if (toks.len >= 3 and std.mem.eql(u8, toks[1], "-Property")) {
            prop = toks[2];
        } else if (toks.len >= 2) {
            prop = toks[1];
        }
        try cmdSortObject(a, prop, input, out);
        return;
    }
    if (std.mem.eql(u8, verb, "Measure-Object")) {
        const w = stdoutWriter();
        try cmdMeasureObject(input, w);
        return;
    }
    return error.UnknownCmdlet;
}

fn runLine(a: std.mem.Allocator, line: []const u8) !void {
    const segs = try splitPipeline(a, line);
    defer a.free(segs);
    if (segs.len == 0) return;

    var cwd_opt: ?[]const u8 = null;
    defer if (cwd_opt) |p| a.free(p);

    var cur = std.ArrayListUnmanaged(Obj){};
    defer deinitObjects(a, &cur);

    const w = stdoutWriter();
    for (segs, 0..) |seg, si| {
        var next = std.ArrayListUnmanaged(Obj){};
        errdefer deinitObjects(a, &next);
        try runSegment(a, seg, &cwd_opt, cur.items, &next);
        deinitObjects(a, &cur);
        cur = next;
        const is_last = si == segs.len - 1;
        if (is_last and std.mem.startsWith(u8, std.mem.trim(u8, seg, " \t"), "Measure-Object")) {
            continue;
        }
        if (is_last and std.mem.startsWith(u8, std.mem.trim(u8, seg, " \t"), "Help")) {
            continue;
        }
        if (is_last) {
            for (cur.items) |*o| try o.print(w);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len < 2) {
        std.debug.print("usage: pwsh-lite '<pipeline>'\n  example: pwsh-lite 'Get-Process | Where-Object Name pwsh | Select-Object -Property Name'\n", .{});
        return error.InvalidArgs;
    }
    const line = try std.mem.join(a, " ", args[1..]);
    defer a.free(line);
    try runLine(a, line);
}

test "splitPipeline trims and skips empty" {
    const a = std.testing.allocator;
    const parts = try splitPipeline(a, "  A | B|| C ");
    defer a.free(parts);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("A", parts[0]);
    try std.testing.expectEqualStrings("B", parts[1]);
    try std.testing.expectEqualStrings("C", parts[2]);
}

test "tokenizeSegment quoted" {
    const a = std.testing.allocator;
    const t = try tokenizeSegment(a, "Get-Item \"a b.txt\"");
    defer a.free(t);
    try std.testing.expectEqual(@as(usize, 2), t.len);
    try std.testing.expectEqualStrings("Get-Item", t[0]);
    try std.testing.expectEqualStrings("a b.txt", t[1]);
}
