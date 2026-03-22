//! I2C 主机协议（7-bit 寻址，主发/主收）。
//! 通过 `Hal` 抽象 GPIO 位带或任意 bit-bang 后端；不绑定具体 SoC 引脚。
//! 参考：UM10204 (I²C-bus specification)。

const std = @import("std");

/// 位带 / GPIO 后端：由平台实现 set_sda、set_scl、读 SDA、半周期延时。
pub const Hal = struct {
    ctx: *anyopaque,
    set_sda: *const fn (ctx: *anyopaque, high: bool) void,
    set_scl: *const fn (ctx: *anyopaque, high: bool) void,
    read_sda: *const fn (ctx: *anyopaque) bool,
    /// 一个 SCL 半周期（低→高 或 高→低）的时序间隔。
    delay_half_period: *const fn (ctx: *anyopaque) void,

    fn sda(self: Hal, high: bool) void {
        self.set_sda(self.ctx, high);
    }

    fn scl(self: Hal, high: bool) void {
        self.set_scl(self.ctx, high);
    }

    fn sda_in(self: Hal) bool {
        return self.read_sda(self.ctx);
    }

    fn wait(self: Hal) void {
        self.delay_half_period(self.ctx);
    }
};

pub const TransferError = error{
    Nack,
};

/// 单条 I2C 总线上的主机会话（持有 Hal 引用，不拥有 ctx）。
pub const Master = struct {
    hal: Hal,

    pub fn init(hal: Hal) Master {
        return .{ .hal = hal };
    }

    fn bus_idle(m: *Master) void {
        m.hal.sda(true);
        m.hal.scl(true);
        m.hal.wait();
    }

    pub fn start(m: *Master) void {
        m.hal.sda(true);
        m.hal.scl(true);
        m.hal.wait();
        m.hal.sda(false);
        m.hal.wait();
        m.hal.scl(false);
        m.hal.wait();
    }

    pub fn stop(m: *Master) void {
        m.hal.sda(false);
        m.hal.scl(false);
        m.hal.wait();
        m.hal.scl(true);
        m.hal.wait();
        m.hal.sda(true);
        m.hal.wait();
    }

    /// 发送一字节；返回从机是否 ACK。
    pub fn writeByte(m: *Master, byte: u8) bool {
        var b = byte;
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            m.hal.sda((b & 0x80) != 0);
            b <<= 1;
            m.hal.wait();
            m.hal.scl(true);
            m.hal.wait();
            m.hal.scl(false);
            m.hal.wait();
        }
        m.hal.sda(true);
        m.hal.wait();
        m.hal.scl(true);
        m.hal.wait();
        const ack = !m.hal.sda_in();
        m.hal.scl(false);
        m.hal.wait();
        return ack;
    }

    /// 读一字节；`ack=true` 时主机拉低 SDA 表示 ACK，否则 NACK。
    pub fn readByte(m: *Master, ack: bool) u8 {
        m.hal.sda(true);
        var out: u8 = 0;
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            m.hal.wait();
            m.hal.scl(true);
            m.hal.wait();
            out = (out << 1) | @as(u8, if (m.hal.sda_in()) 1 else 0);
            m.hal.scl(false);
            m.hal.wait();
        }
        m.hal.sda(!ack);
        m.hal.wait();
        m.hal.scl(true);
        m.hal.wait();
        m.hal.scl(false);
        m.hal.wait();
        m.hal.sda(true);
        return out;
    }

    /// 7-bit 地址 + 读写位（0=写，1=读）。
    pub fn addressByte(addr7: u7, read: bool) u8 {
        return (@as(u8, @intCast(addr7)) << 1) | @as(u8, if (read) 1 else 0);
    }

    /// 写事务：START + 地址写 + `payload`，以 STOP 结束。任一字节无 ACK 则返回错误。
    pub fn writeAll(m: *Master, addr7: u7, payload: []const u8) TransferError!void {
        m.bus_idle();
        m.start();
        if (!m.writeByte(addressByte(addr7, false))) {
            m.stop();
            return error.Nack;
        }
        for (payload) |byte| {
            if (!m.writeByte(byte)) {
                m.stop();
                return error.Nack;
            }
        }
        m.stop();
    }

    /// 组合写后读（常见于寄存器：先写寄存器地址再读数据）。
    pub fn writeThenRead(
        m: *Master,
        addr7: u7,
        write_part: []const u8,
        read_part: []u8,
    ) TransferError!void {
        m.bus_idle();
        m.start();
        if (!m.writeByte(addressByte(addr7, false))) {
            m.stop();
            return error.Nack;
        }
        for (write_part) |byte| {
            if (!m.writeByte(byte)) {
                m.stop();
                return error.Nack;
            }
        }
        m.start();
        if (!m.writeByte(addressByte(addr7, true))) {
            m.stop();
            return error.Nack;
        }
        if (read_part.len == 0) {
            m.stop();
            return;
        }
        var i: usize = 0;
        while (i < read_part.len) : (i += 1) {
            const last = i + 1 == read_part.len;
            read_part[i] = m.readByte(!last);
        }
        m.stop();
    }

    /// 纯读：START + 读地址 + 读 `out` 长度字节 + STOP。
    pub fn readAll(m: *Master, addr7: u7, out: []u8) TransferError!void {
        m.bus_idle();
        m.start();
        if (!m.writeByte(addressByte(addr7, true))) {
            m.stop();
            return error.Nack;
        }
        if (out.len == 0) {
            m.stop();
            return;
        }
        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            const last = i + 1 == out.len;
            out[i] = m.readByte(!last);
        }
        m.stop();
    }
};

/// 测试/仿真用：用内存记录 SDA/SCL 电平，不访问真实硬件。
pub const SimLines = struct {
    sda_high: bool = true,
    scl_high: bool = true,
    /// 主机输出时从机采样的 SDA（仿真从机应答）
    slave_ack: bool = true,

    pub fn hal(self: *SimLines) Hal {
        return .{
            .ctx = @ptrCast(self),
            .set_sda = simSetSda,
            .set_scl = simSetScl,
            .read_sda = simReadSda,
            .delay_half_period = simDelay,
        };
    }

    fn simSetSda(ctx: *anyopaque, high: bool) void {
        const s: *SimLines = @ptrCast(@alignCast(ctx));
        s.sda_high = high;
    }

    fn simSetScl(ctx: *anyopaque, high: bool) void {
        const s: *SimLines = @ptrCast(@alignCast(ctx));
        s.scl_high = high;
    }

    fn simReadSda(ctx: *anyopaque) bool {
        const s: *SimLines = @ptrCast(@alignCast(ctx));
        // ACK：从机拉低 SDA → 读为低（false）
        return !s.slave_ack;
    }

    fn simDelay(_: *anyopaque) void {}
};

test "i2c address byte" {
    try std.testing.expectEqual(@as(u8, 0x42), Master.addressByte(0x21, false));
    try std.testing.expectEqual(@as(u8, 0x43), Master.addressByte(0x21, true));
}
