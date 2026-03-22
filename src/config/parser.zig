//! INI-style configuration parser for ZirconOS.
//! Parses `[section]` headers and `key = value` pairs from embedded config data.
//! Designed for freestanding environments — no allocator required.

const klog = @import("../rtl/klog.zig");

pub const MAX_ENTRIES = 256;
pub const MAX_KEY_LEN = 64;
pub const MAX_VALUE_LEN = 128;
pub const MAX_SECTION_LEN = 32;

pub const Entry = struct {
    section: [MAX_SECTION_LEN]u8 = .{0} ** MAX_SECTION_LEN,
    section_len: usize = 0,
    key: [MAX_KEY_LEN]u8 = .{0} ** MAX_KEY_LEN,
    key_len: usize = 0,
    value: [MAX_VALUE_LEN]u8 = .{0} ** MAX_VALUE_LEN,
    value_len: usize = 0,

    pub fn sectionSlice(self: *const Entry) []const u8 {
        return self.section[0..self.section_len];
    }

    pub fn keySlice(self: *const Entry) []const u8 {
        return self.key[0..self.key_len];
    }

    pub fn valueSlice(self: *const Entry) []const u8 {
        return self.value[0..self.value_len];
    }
};

pub const Config = struct {
    entries: [MAX_ENTRIES]Entry = undefined,
    count: usize = 0,

    pub fn parse(self: *Config, data: []const u8) void {
        self.count = 0;
        var current_section: [MAX_SECTION_LEN]u8 = .{0} ** MAX_SECTION_LEN;
        var current_section_len: usize = 0;

        var line_start: usize = 0;
        var pos: usize = 0;

        while (pos <= data.len) {
            const at_end = pos == data.len;
            const is_newline = !at_end and data[pos] == '\n';

            if (is_newline or at_end) {
                var line_end = pos;
                if (line_end > line_start and line_end > 0 and data[line_end - 1] == '\r') {
                    line_end -= 1;
                }

                const line = data[line_start..line_end];
                const trimmed = trimWhitespace(line);

                if (trimmed.len > 0 and trimmed[0] != '#' and trimmed[0] != ';') {
                    if (trimmed[0] == '[') {
                        if (parseSectionHeader(trimmed)) |sec| {
                            current_section_len = @min(sec.len, MAX_SECTION_LEN);
                            copySlice(&current_section, sec[0..current_section_len]);
                        }
                    } else {
                        if (parseKeyValue(trimmed)) |kv| {
                            if (self.count < MAX_ENTRIES) {
                                var entry = &self.entries[self.count];
                                entry.* = Entry{};
                                entry.section_len = current_section_len;
                                copySlice(&entry.section, current_section[0..current_section_len]);
                                entry.key_len = @min(kv.key.len, MAX_KEY_LEN);
                                copySlice(&entry.key, kv.key[0..entry.key_len]);
                                entry.value_len = @min(kv.value.len, MAX_VALUE_LEN);
                                copySlice(&entry.value, kv.value[0..entry.value_len]);
                                self.count += 1;
                            }
                        }
                    }
                }

                line_start = pos + 1;
            }
            pos += 1;
        }
    }

    pub fn get(self: *const Config, section: []const u8, key: []const u8) ?[]const u8 {
        for (self.entries[0..self.count]) |*entry| {
            if (eqlSlice(entry.sectionSlice(), section) and eqlSlice(entry.keySlice(), key)) {
                return entry.valueSlice();
            }
        }
        return null;
    }

    pub fn getOr(self: *const Config, section: []const u8, key: []const u8, default: []const u8) []const u8 {
        return self.get(section, key) orelse default;
    }

    pub fn getInt(self: *const Config, section: []const u8, key: []const u8) ?u64 {
        const val = self.get(section, key) orelse return null;
        return parseUint(val);
    }

    pub fn getIntOr(self: *const Config, section: []const u8, key: []const u8, default: u64) u64 {
        return self.getInt(section, key) orelse default;
    }

    pub fn getBool(self: *const Config, section: []const u8, key: []const u8) ?bool {
        const val = self.get(section, key) orelse return null;
        if (eqlSlice(val, "true") or eqlSlice(val, "yes") or eqlSlice(val, "1")) return true;
        if (eqlSlice(val, "false") or eqlSlice(val, "no") or eqlSlice(val, "0")) return false;
        return null;
    }

    pub fn getBoolOr(self: *const Config, section: []const u8, key: []const u8, default: bool) bool {
        return self.getBool(section, key) orelse default;
    }

    pub fn getHex(self: *const Config, section: []const u8, key: []const u8) ?u64 {
        const val = self.get(section, key) orelse return null;
        if (val.len > 2 and val[0] == '0' and (val[1] == 'x' or val[1] == 'X')) {
            return parseHex(val[2..]);
        }
        return parseHex(val);
    }

    pub fn getHexOr(self: *const Config, section: []const u8, key: []const u8, default: u64) u64 {
        return self.getHex(section, key) orelse default;
    }

    pub fn getEntryCount(self: *const Config) usize {
        return self.count;
    }

    pub fn dump(self: *const Config) void {
        klog.info("Config: %u entries loaded", .{self.count});
        for (self.entries[0..self.count]) |*entry| {
            klog.debug("  [%s] %s = %s", .{
                entry.sectionSlice(),
                entry.keySlice(),
                entry.valueSlice(),
            });
        }
    }
};

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

fn parseSectionHeader(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '[') return null;
    var end: usize = 1;
    while (end < line.len and line[end] != ']') : (end += 1) {}
    if (end >= line.len) return null;
    return trimWhitespace(line[1..end]);
}

fn parseKeyValue(line: []const u8) ?KeyValue {
    var eq_pos: usize = 0;
    var found = false;
    while (eq_pos < line.len) : (eq_pos += 1) {
        if (line[eq_pos] == '=') {
            found = true;
            break;
        }
    }
    if (!found) return null;

    const raw_key = trimWhitespace(line[0..eq_pos]);
    const raw_value = if (eq_pos + 1 < line.len)
        trimWhitespace(line[eq_pos + 1 ..])
    else
        "";

    if (raw_key.len == 0) return null;
    return KeyValue{ .key = raw_key, .value = raw_value };
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1) {}
    return s[start..end];
}

fn eqlSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn copySlice(dst: []u8, src: []const u8) void {
    const n = @min(dst.len, src.len);
    for (dst[0..n], src[0..n]) |*d, s| {
        d.* = s;
    }
}

fn parseUint(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        return parseHex(s[2..]);
    }
    var result: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const old = result;
        result = result *% 10 +% (c - '0');
        if (result < old) return null;
    }
    return result;
}

fn parseHex(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var result: u64 = 0;
    for (s) |c| {
        const digit: u64 = if (c >= '0' and c <= '9')
            c - '0'
        else if (c >= 'a' and c <= 'f')
            c - 'a' + 10
        else if (c >= 'A' and c <= 'F')
            c - 'A' + 10
        else
            return null;
        result = result *% 16 +% digit;
    }
    return result;
}
