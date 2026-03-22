//! 串口（UART）类驱动：在 I/O 管理器上注册 COM1（16550）字符设备。
//! 硬件访问复用 `hal/x86_64/serial.zig`；IRP read/write 用于收发缓冲。

const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");

const serial = if (builtin.target.cpu.arch == .x86_64)
    @import("../../hal/x86_64/serial.zig")
else
    struct {
        pub fn isReady() bool {
            return false;
        }
        pub fn hasData() bool {
            return false;
        }
        pub fn readByte() ?u8 {
            return null;
        }
        pub fn writeByte(_: u8) void {}
    };

pub const IOCTL_SERIAL_GET_READY: u32 = 0x000B0000;
pub const IOCTL_SERIAL_RX_PENDING: u32 = 0x000B0001;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

fn serialDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .read => {
            if (irp.buffer_size == 0 or irp.buffer_ptr == 0) {
                irp.bytes_transferred = 0;
                irp.complete(.success, 0);
                return .success;
            }
            const buf: [*]u8 = @ptrFromInt(irp.buffer_ptr);
            var n: usize = 0;
            while (n < irp.buffer_size) {
                if (serial.readByte()) |b| {
                    buf[n] = b;
                    n += 1;
                } else {
                    break;
                }
            }
            irp.bytes_transferred = n;
            irp.complete(.success, n);
            return .success;
        },
        .write => {
            if (irp.buffer_size == 0 or irp.buffer_ptr == 0) {
                irp.bytes_transferred = 0;
                irp.complete(.success, 0);
                return .success;
            }
            const buf: [*]const u8 = @ptrFromInt(irp.buffer_ptr);
            var n: usize = 0;
            while (n < irp.buffer_size) : (n += 1) {
                serial.writeByte(buf[n]);
            }
            irp.bytes_transferred = n;
            irp.complete(.success, n);
            return .success;
        },
        .ioctl => {
            switch (irp.ioctl_code) {
                IOCTL_SERIAL_GET_READY => {
                    irp.bytes_transferred = if (serial.isReady()) 1 else 0;
                    irp.complete(.success, irp.bytes_transferred);
                    return .success;
                },
                IOCTL_SERIAL_RX_PENDING => {
                    irp.bytes_transferred = if (serial.hasData()) 1 else 0;
                    irp.complete(.success, irp.bytes_transferred);
                    return .success;
                },
                else => {
                    irp.complete(.not_implemented, 0);
                    return .not_implemented;
                },
            }
        },
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

pub fn init() void {
    if (builtin.target.cpu.arch != .x86_64) {
        klog.info("Serial bus: skipped (no COM1 on this arch)", .{});
        return;
    }

    driver_idx = io.registerDriver("\\Driver\\Serial", serialDispatch) orelse {
        klog.err("Serial: Failed to register driver", .{});
        return;
    };

    device_idx = io.createDevice("\\Device\\Serial0", .serial, driver_idx) orelse {
        klog.err("Serial: Failed to create \\Device\\Serial0", .{});
        return;
    };

    driver_initialized = true;
    klog.info("Serial: \\Device\\Serial0 (COM1) registered for IRP read/write", .{});
}

pub fn isInitialized() bool {
    return driver_initialized;
}

pub fn getDeviceIndex() u32 {
    return device_idx;
}
