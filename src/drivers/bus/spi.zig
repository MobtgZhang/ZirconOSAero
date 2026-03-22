//! SPI 主机协议（Mode 0：CPOL=0, CPHA=0），bit-bang 后端。
//! 时钟空闲为低，在上升沿采样 MISO、在上升沿之前设置 MOSI。

const std = @import("std");

pub const Hal = struct {
    ctx: *anyopaque,
    set_cs: *const fn (ctx: *anyopaque, active_low: bool) void,
    set_sck: *const fn (ctx: *anyopaque, high: bool) void,
    set_mosi: *const fn (ctx: *anyopaque, high: bool) void,
    read_miso: *const fn (ctx: *anyopaque) bool,
    delay_half_cycle: *const fn (ctx: *anyopaque) void,
};

pub const Master = struct {
    hal: Hal,

    pub fn init(hal: Hal) Master {
        return .{ .hal = hal };
    }

    fn half(m: *Master) void {
        m.hal.delay_half_cycle(m.hal.ctx);
    }

    /// 传输一字节（MSB 先），返回读回的一字节。
    pub fn transferByte(m: *Master, out: u8) u8 {
        var rx: u8 = 0;
        var b = out;
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            m.hal.set_mosi(m.hal.ctx, (b & 0x80) != 0);
            b <<= 1;
            m.half();
            m.hal.set_sck(m.hal.ctx, true);
            m.half();
            rx = (rx << 1) | @as(u8, if (m.hal.read_miso(m.hal.ctx)) 1 else 0);
            m.hal.set_sck(m.hal.ctx, false);
            m.half();
        }
        return rx;
    }

    /// CS 有效 → 多字节全双工传输（同时写 `out`、读入 `in_out`）。
    pub fn transfer(m: *Master, out: []const u8, in_out: []u8) void {
        const n = @min(out.len, in_out.len);
        m.hal.set_cs(m.hal.ctx, true);
        m.half();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            in_out[i] = m.transferByte(out[i]);
        }
        m.half();
        m.hal.set_cs(m.hal.ctx, false);
        m.half();
    }

    /// 只写（忽略 MISO）。
    pub fn writeOnly(m: *Master, out: []const u8) void {
        m.hal.set_cs(m.hal.ctx, true);
        m.half();
        for (out) |byte| {
            _ = m.transferByte(byte);
        }
        m.half();
        m.hal.set_cs(m.hal.ctx, false);
        m.half();
    }

    /// 只读：主机发 dummy 0xFF，结果写入 `buf`。
    pub fn readOnly(m: *Master, buf: []u8) void {
        m.hal.set_cs(m.hal.ctx, true);
        m.half();
        var i: usize = 0;
        while (i < buf.len) : (i += 1) {
            buf[i] = m.transferByte(0xFF);
        }
        m.half();
        m.hal.set_cs(m.hal.ctx, false);
        m.half();
    }
};

test "spi transfer byte identity miso 0" {
    var sim = SimSpi{};
    var master = Master.init(sim.hal());
    sim.miso_high = false;
    const v = master.transferByte(0xA5);
    try std.testing.expectEqual(@as(u8, 0), v);
}

/// 简单仿真：记录 MOSI 移位，MISO 恒为配置值。
const SimSpi = struct {
    miso_high: bool = false,

    pub fn hal(self: *SimSpi) Hal {
        return .{
            .ctx = @ptrCast(self),
            .set_cs = simCs,
            .set_sck = simSck,
            .set_mosi = simMosi,
            .read_miso = simMiso,
            .delay_half_cycle = simDelay,
        };
    }

    fn simCs(_: *anyopaque, _: bool) void {}
    fn simSck(_: *anyopaque, _: bool) void {}
    fn simMosi(_: *anyopaque, _: bool) void {}
    fn simMiso(ctx: *anyopaque) bool {
        const s: *SimSpi = @ptrCast(@alignCast(ctx));
        return s.miso_high;
    }
    fn simDelay(_: *anyopaque) void {}
};
