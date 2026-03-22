//! Console Runtime Subsystem
//! Manages console windows, input/output buffers, and console API dispatch.
//! Implements NT-compatible console hosting and driver model.

const arch = @import("../../arch.zig");
const klog = @import("../../rtl/klog.zig");
const ob = @import("../../ob/object.zig");

const MAX_CONSOLES: usize = 8;
const INPUT_BUFFER_SIZE: usize = 256;
const OUTPUT_BUFFER_SIZE: usize = 4096;
const MAX_CONSOLE_WIDTH: usize = 80;
const MAX_CONSOLE_HEIGHT: usize = 25;

pub const ConsoleColor = enum(u8) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_magenta = 13,
    yellow = 14,
    white = 15,
};

pub const ConsoleAttributes = struct {
    fg_color: ConsoleColor = .light_gray,
    bg_color: ConsoleColor = .black,
    cursor_visible: bool = true,
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    width: usize = MAX_CONSOLE_WIDTH,
    height: usize = MAX_CONSOLE_HEIGHT,
};

pub const Console = struct {
    header: ob.ObjectHeader = .{ .obj_type = .device },
    id: u32 = 0,
    process_id: u32 = 0,
    is_active: bool = false,
    title: [64]u8 = [_]u8{0} ** 64,
    title_len: usize = 0,
    attrs: ConsoleAttributes = .{},
    input_buffer: [INPUT_BUFFER_SIZE]u8 = [_]u8{0} ** INPUT_BUFFER_SIZE,
    input_len: usize = 0,
    input_pos: usize = 0,
    output_buffer: [OUTPUT_BUFFER_SIZE]u8 = [_]u8{0} ** OUTPUT_BUFFER_SIZE,
    output_len: usize = 0,

    pub fn writeOutput(self: *Console, data: []const u8) usize {
        var written: usize = 0;
        for (data) |c| {
            if (self.output_len >= OUTPUT_BUFFER_SIZE) break;
            self.output_buffer[self.output_len] = c;
            self.output_len += 1;
            written += 1;
        }
        arch.consoleWrite(data);
        return written;
    }

    pub fn writeLine(self: *Console, line: []const u8) void {
        _ = self.writeOutput(line);
        _ = self.writeOutput("\n");
    }

    pub fn readInput(self: *Console, buffer: []u8) usize {
        var read_count: usize = 0;
        while (read_count < buffer.len and self.input_pos < self.input_len) {
            buffer[read_count] = self.input_buffer[self.input_pos];
            self.input_pos += 1;
            read_count += 1;
        }
        if (self.input_pos >= self.input_len) {
            self.input_pos = 0;
            self.input_len = 0;
        }
        return read_count;
    }

    pub fn pushInput(self: *Console, data: []const u8) usize {
        var pushed: usize = 0;
        for (data) |c| {
            if (self.input_len >= INPUT_BUFFER_SIZE) break;
            self.input_buffer[self.input_len] = c;
            self.input_len += 1;
            pushed += 1;
        }
        return pushed;
    }

    pub fn setTitle(self: *Console, title: []const u8) void {
        const copy_len = @min(title.len, self.title.len);
        @memcpy(self.title[0..copy_len], title[0..copy_len]);
        self.title_len = copy_len;
    }

    pub fn clear(self: *Console) void {
        self.output_len = 0;
        self.attrs.cursor_x = 0;
        self.attrs.cursor_y = 0;
        arch.consoleClear();
    }

    pub fn setColor(self: *Console, fg: ConsoleColor, bg: ConsoleColor) void {
        self.attrs.fg_color = fg;
        self.attrs.bg_color = bg;
    }
};

var consoles: [MAX_CONSOLES]Console = [_]Console{.{}} ** MAX_CONSOLES;
var console_count: u32 = 0;
var active_console: u32 = 0;
var console_initialized: bool = false;

pub fn init() void {
    console_count = 0;
    active_console = 0;
    console_initialized = true;

    const con = createConsole(1, "ZirconOS Console") orelse return;
    _ = con;

    klog.info("Console: Runtime initialized", .{});
}

pub fn createConsole(process_id: u32, title: []const u8) ?*Console {
    if (console_count >= MAX_CONSOLES) return null;

    var con = &consoles[console_count];
    con.* = .{};
    con.id = console_count;
    con.process_id = process_id;
    con.is_active = true;
    con.setTitle(title);

    if (console_count == 0) {
        active_console = con.id;
    }

    console_count += 1;
    return con;
}

pub fn getActiveConsole() ?*Console {
    if (!console_initialized or console_count == 0) return null;
    if (active_console < console_count) {
        return &consoles[active_console];
    }
    return null;
}

pub fn getConsole(id: u32) ?*Console {
    if (id < console_count) {
        return &consoles[id];
    }
    return null;
}

pub fn setActiveConsole(id: u32) bool {
    if (id < console_count) {
        active_console = id;
        return true;
    }
    return false;
}

pub fn writeToActive(data: []const u8) usize {
    const con = getActiveConsole() orelse return 0;
    return con.writeOutput(data);
}

pub fn getConsoleCount() u32 {
    return console_count;
}

pub fn isInitialized() bool {
    return console_initialized;
}
