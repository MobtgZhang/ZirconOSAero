const builtin = @import("builtin");

export fn __extendsfdf2(a: f32) f64 {
    return @as(f64, a);
}
export fn __truncdfsf2(a: f64) f32 {
    return @as(f32, @floatCast(a));
}
export fn __subdf3(a: f64, b: f64) f64 {
    return a - b;
}
export fn __subsf3(a: f32, b: f32) f32 {
    return a - b;
}
export fn __adddf3(a: f64, b: f64) f64 {
    return a + b;
}
export fn __addsf3(a: f32, b: f32) f32 {
    return a + b;
}
export fn __muldf3(a: f64, b: f64) f64 {
    return a * b;
}
export fn __mulsf3(a: f32, b: f32) f32 {
    return a * b;
}
export fn __divdf3(a: f64, b: f64) f64 {
    return a / b;
}
export fn __divsf3(a: f32, b: f32) f32 {
    return a / b;
}
export fn __negdf2(a: f64) f64 {
    return -a;
}
export fn __negsf2(a: f32) f32 {
    return -a;
}
export fn __floatsisf(a: i32) f32 {
    return @floatFromInt(a);
}
export fn __floatsidf(a: i32) f64 {
    return @floatFromInt(a);
}
export fn __floatdisf(a: i64) f32 {
    return @floatFromInt(a);
}
export fn __floatdidf(a: i64) f64 {
    return @floatFromInt(a);
}
export fn __floatunsisf(a: u32) f32 {
    return @floatFromInt(a);
}
export fn __floatunsidf(a: u32) f64 {
    return @floatFromInt(a);
}
export fn __floatundisf(a: u64) f32 {
    return @floatFromInt(a);
}
export fn __floatundidf(a: u64) f64 {
    return @floatFromInt(a);
}
export fn __fixsfsi(a: f32) i32 {
    return @intFromFloat(a);
}
export fn __fixdfsi(a: f64) i32 {
    return @intFromFloat(a);
}
export fn __fixsfdi(a: f32) i64 {
    return @intFromFloat(a);
}
export fn __fixdfdi(a: f64) i64 {
    return @intFromFloat(a);
}
export fn __fixunssfsi(a: f32) u32 {
    return @intFromFloat(a);
}
export fn __fixunsdfsi(a: f64) u32 {
    return @intFromFloat(a);
}
export fn __fixunssfdi(a: f32) u64 {
    return @intFromFloat(a);
}
export fn __fixunsdfdi(a: f64) u64 {
    return @intFromFloat(a);
}
export fn __ltsf2(a: f32, b: f32) i32 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}
export fn __gtsf2(a: f32, b: f32) i32 {
    if (a > b) return 1;
    if (a < b) return -1;
    return 0;
}
export fn __lesf2(a: f32, b: f32) i32 {
    if (a <= b) return -1;
    return 1;
}
export fn __gesf2(a: f32, b: f32) i32 {
    if (a >= b) return 1;
    return -1;
}
export fn __ltdf2(a: f64, b: f64) i32 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}
export fn __gtdf2(a: f64, b: f64) i32 {
    if (a > b) return 1;
    if (a < b) return -1;
    return 0;
}
export fn __ledf2(a: f64, b: f64) i32 {
    if (a <= b) return -1;
    return 1;
}
export fn __gedf2(a: f64, b: f64) i32 {
    if (a >= b) return 1;
    return -1;
}
export fn __eqsf2(a: f32, b: f32) i32 {
    if (a == b) return 0;
    return 1;
}
export fn __nedf2(a: f64, b: f64) i32 {
    if (a != b) return 1;
    return 0;
}
export fn __eqdf2(a: f64, b: f64) i32 {
    if (a == b) return 0;
    return 1;
}
export fn __nesf2(a: f32, b: f32) i32 {
    if (a != b) return 1;
    return 0;
}
export fn __unorddf2(a: f64, b: f64) i32 {
    if (a != a or b != b) return 1;
    return 0;
}
export fn __unordsf2(a: f32, b: f32) i32 {
    if (a != a or b != b) return 1;
    return 0;
}
export fn sqrtf(x: f32) f32 {
    return @sqrt(x);
}
export fn sqrt(x: f64) f64 {
    return @sqrt(x);
}
export fn roundf(x: f32) f32 {
    return @round(x);
}
export fn round(x: f64) f64 {
    return @round(x);
}
export fn floorf(x: f32) f32 {
    return @floor(x);
}
export fn floor(x: f64) f64 {
    return @floor(x);
}
export fn ceilf(x: f32) f32 {
    return @ceil(x);
}
export fn ceil(x: f64) f64 {
    return @ceil(x);
}
export fn fmaxf(a: f32, b: f32) f32 {
    return @max(a, b);
}
export fn fmax(a: f64, b: f64) f64 {
    return @max(a, b);
}
export fn fminf(a: f32, b: f32) f32 {
    return @min(a, b);
}
export fn fmin(a: f64, b: f64) f64 {
    return @min(a, b);
}
export fn fabsf(x: f32) f32 {
    return @abs(x);
}
export fn fabs(x: f64) f64 {
    return @abs(x);
}
export fn fmaf(a: f32, b: f32, c: f32) f32 {
    return @mulAdd(f32, a, b, c);
}
export fn fma(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, a, b, c);
}
export fn __mulosi4(a: i32, b: i32, overflow: *c_int) i32 {
    const r: i64 = @as(i64, a) * @as(i64, b);
    const clamped: i32 = @truncate(r);
    overflow.* = @intFromBool(clamped != r);
    return clamped;
}
export fn __mulodi4(a: i64, b: i64, overflow: *i32) i64 {
    const result = @mulWithOverflow(a, b);
    overflow.* = @intFromBool(result[1] != 0);
    return result[0];
}
export fn __muloti4(a: i128, b: i128, overflow: *i32) i128 {
    const result = @mulWithOverflow(a, b);
    overflow.* = @intFromBool(result[1] != 0);
    return result[0];
}
export fn __addosi4(a: i32, b: i32, overflow: *c_int) i32 {
    const r, const ov = @addWithOverflow(a, b);
    overflow.* = @intFromBool(ov != 0);
    return r;
}
export fn __addodi4(a: i64, b: i64, overflow: *i32) i64 {
    const r, const ov = @addWithOverflow(a, b);
    overflow.* = @intFromBool(ov != 0);
    return r;
}
export fn __subosi4(a: i32, b: i32, overflow: *c_int) i32 {
    const r, const ov = @subWithOverflow(a, b);
    overflow.* = @intFromBool(ov != 0);
    return r;
}
export fn __subodi4(a: i64, b: i64, overflow: *i32) i64 {
    const r, const ov = @subWithOverflow(a, b);
    overflow.* = @intFromBool(ov != 0);
    return r;
}
export fn __popcountdi2(x: u64) i32 {
    return @popCount(x);
}
export fn __popcountsi2(x: i32) i32 {
    return @popCount(x);
}
export fn __clzsi2(x: i32) i32 {
    return @clz(x);
}
export fn __clzdi2(x: i64) i32 {
    return @clz(x);
}
export fn __ctzsi2(x: i32) i32 {
    return @ctz(x);
}
export fn __ctzdi2(x: i64) i32 {
    return @ctz(x);
}
export fn __bswapsi2(x: u32) u32 {
    return @byteSwap(x);
}
export fn __bswapdi2(x: u64) u64 {
    return @byteSwap(x);
}
export fn __ashldi3(a: i64, b: i32) i64 {
    return a << @intCast(@as(u6, @truncate(@as(u32, @bitCast(b)))));
}
export fn __lshrdi3(a: u64, b: i32) u64 {
    return a >> @intCast(@as(u6, @truncate(@as(u32, @bitCast(b)))));
}
export fn __ashrdi3(a: i64, b: i32) i64 {
    return a >> @intCast(@as(u6, @truncate(@as(u32, @bitCast(b)))));
}
export fn __udivti3(a: u128, b: u128) u128 {
    return a / b;
}
export fn __umodti3(a: u128, b: u128) u128 {
    return a % b;
}
export fn __extenddftf2(a: f64) f128 {
    return @as(f128, a);
}
export fn __extendxftf2(a: f80) f128 {
    return @as(f128, a);
}
export fn memset(dest: ?[*]u8, c: u8, len: usize) ?[*]u8 {
    if (dest) |d| {
        for (d[0..len]) |*p| {
            p.* = c;
        }
    }
    return dest;
}
export fn memcpy(dest: ?[*]u8, src: ?[*]const u8, len: usize) ?[*]u8 {
    if (dest == null or src == null) return dest;
    const d = dest.?;
    const s = src.?;
    for (0..len) |i| {
        d[i] = s[i];
    }
    return dest;
}
export fn fmodf(x: f32, y: f32) f32 {
    if (y == 0) return 0;
    var result = @abs(x);
    const abs_y = @abs(y);
    while (result >= abs_y) {
        result -= abs_y;
    }
    return if (x < 0) -result else result;
}
export fn __zig_probe_stack(sp: usize) void {
    _ = sp;
}
export fn memmove(dest: ?[*]u8, src: ?[*]const u8, len: usize) ?[*]u8 {
    if (dest == null or src == null) return dest;
    const d = dest.?;
    const s = src.?;
    if (@intFromPtr(d) < @intFromPtr(s)) {
        for (0..len) |i| {
            d[i] = s[i];
        }
    } else {
        var i = len;
        while (i > 0) {
            i -= 1;
            d[i] = s[i];
        }
    }
    return dest;
}
export fn cosf(x: f32) f32 {
    const pi: f32 = 3.14159265358979;
    var y = @mod(x, 2 * pi);
    if (y < 0) y += 2 * pi;
    if (y > pi) y -= 2 * pi;
    var term: f32 = 1;
    var result: f32 = 1;
    var n: u32 = 2;
    var sign: f32 = -1;
    while (n < 20) : (n += 2) {
        var fact: f32 = 1;
        for (n - 1..n + 1) |i| {
            fact *= @floatFromInt(i + 1);
        }
        term *= y * y / fact;
        result += sign * term;
        sign = -sign;
    }
    return result;
}
export fn sinf(x: f32) f32 {
    const pi: f32 = 3.14159265358979;
    var y = @mod(x, 2 * pi);
    if (y > pi) y -= 2 * pi;
    if (y < -pi) y += 2 * pi;
    var term: f32 = y;
    var result: f32 = y;
    var n: u32 = 3;
    var sign: f32 = -1;
    while (n < 20) : (n += 2) {
        var fact: f32 = 1;
        for (0..n) |i| {
            fact *= @floatFromInt(i + 1);
        }
        term *= y * y / fact;
        result += sign * term;
        sign = -sign;
    }
    return result;
}
