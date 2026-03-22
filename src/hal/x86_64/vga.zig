const VGA_WIDTH: usize = 80;
const VGA_HEIGHT: usize = 25;

const Color = enum(u8) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_grey = 7,
    dark_grey = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_magenta = 13,
    light_brown = 14,
    white = 15,
};

const Cell = packed struct {
    ch: u8,
    attr: u8,
};

const Buffer = [VGA_WIDTH * VGA_HEIGHT]Cell;

var row: usize = 0;
var col: usize = 0;
var attr: u8 = makeAttr(.light_grey, .black);

fn buf() *volatile Buffer {
    return @ptrFromInt(0xB8000);
}

pub fn clear() void {
    row = 0;
    col = 0;
    const b = buf();
    for (0..VGA_WIDTH * VGA_HEIGHT) |i| {
        b[i] = .{ .ch = ' ', .attr = attr };
    }
}

pub fn write(s: []const u8) void {
    for (s) |c| putChar(c);
}

fn putChar(c: u8) void {
    switch (c) {
        '\n' => newLine(),
        '\r' => col = 0,
        else => {
            if (col >= VGA_WIDTH) newLine();
            const i = row * VGA_WIDTH + col;
            buf()[i] = .{ .ch = c, .attr = attr };
            col += 1;
        },
    }
}

fn newLine() void {
    col = 0;
    if (row + 1 < VGA_HEIGHT) {
        row += 1;
        return;
    }
    scroll();
}

fn scroll() void {
    const b = buf();
    var y: usize = 1;
    while (y < VGA_HEIGHT) : (y += 1) {
        var x: usize = 0;
        while (x < VGA_WIDTH) : (x += 1) {
            b[(y - 1) * VGA_WIDTH + x] = b[y * VGA_WIDTH + x];
        }
    }
    var x: usize = 0;
    while (x < VGA_WIDTH) : (x += 1) {
        b[(VGA_HEIGHT - 1) * VGA_WIDTH + x] = .{ .ch = ' ', .attr = attr };
    }
}

fn makeAttr(fg: Color, bg: Color) u8 {
    return (@as(u8, @intFromEnum(fg)) & 0x0F) | ((@as(u8, @intFromEnum(bg)) & 0x0F) << 4);
}

pub fn setColor(fg: Color, bg: Color) void {
    attr = makeAttr(fg, bg);
}
