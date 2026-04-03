//! PS/2 mouse class driver (NT6: mouclass + i8042prt auxiliary device)
//! IRQ12 / i8042 aux port; absolute/relative state and event queue for the shell/DWM.
//! Registers `\\Driver\\Mouse` / `\\Device\\Mouse0`. Reference: OSDev PS/2 mouse.

const builtin = @import("builtin");
const std = @import("std");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");
const portio = if (builtin.target.cpu.arch == .x86_64)
    @import("../../hal/x86_64/portio.zig")
else
    struct {
        pub fn outb(_: u16, _: u8) void {}
        pub fn inb(_: u16) u8 {
            return 0;
        }
        pub fn ioWait() void {}
    };

const hal_kbd = if (builtin.target.cpu.arch == .x86_64)
    @import("../../hal/x86_64/keyboard.zig")
else
    struct {
        pub fn handleScancodeByte(_: u8) void {}
    };

const KB_DATA_PORT: u16 = 0x60;
const KB_STATUS_PORT: u16 = 0x64;
const KB_CMD_PORT: u16 = 0x64;

pub const MouseButton = enum(u8) {
    none = 0,
    left = 1,
    right = 2,
    middle = 4,
};

pub const MouseEvent = struct {
    dx: i16 = 0,
    dy: i16 = 0,
    buttons: u8 = 0,
    scroll: i8 = 0,
};

pub const MouseState = struct {
    x: i32 = 0,
    y: i32 = 0,
    raw_x: i32 = 0,
    raw_y: i32 = 0,
    sub_x: i32 = 0,
    sub_y: i32 = 0,
    velocity_x: i32 = 0,
    velocity_y: i32 = 0,
    prev_dx: i32 = 0,
    prev_dy: i32 = 0,
    buttons: u8 = 0,
    left_pressed: bool = false,
    right_pressed: bool = false,
    middle_pressed: bool = false,
    screen_width: i32 = 1280,
    screen_height: i32 = 800,
    /// 相对运动缩放：数值 N 表示 N/10（10 = 1:1 像素，与 30days/UEFI 式「直接累加 dx/dy」一致）。
    sensitivity: i32 = 10,
    acceleration_enabled: bool = false,
    acceleration_threshold: i32 = 3,
    acceleration_curve: i32 = 5,
    /// 子步插值：单轮 `input_hub.pollAll` 内合并后的位移拆成多帧，减轻阶跃感。
    interpolation_enabled: bool = true,
    interpolation_steps: u8 = 3,
    interpolation_idx: u8 = 0,
    smoothing_enabled: bool = false,
    cursor_moved: bool = false,
    /// `HKCU\Control Panel\Mouse` — `DoubleClickSpeed`（毫秒量级，注册表常见 200–900）。
    double_click_time_ms: u32 = 500,
    /// 双击矩形宽/高（像素），与 `DoubleClickWidth` / `DoubleClickHeight` 对齐。
    double_click_width: u32 = 4,
    double_click_height: u32 = 4,
};

const EVENT_QUEUE_SIZE: usize = 64;
var event_queue: [EVENT_QUEUE_SIZE]MouseEvent = [_]MouseEvent{.{}} ** EVENT_QUEUE_SIZE;
var queue_head: usize = 0;
var queue_tail: usize = 0;

var packet_buf: [4]u8 = [_]u8{0} ** 4;
var packet_idx: usize = 0;
var has_scroll_wheel: bool = false;
/// 当前半包起始 tick；超时则丢弃半包，避免永远等不到第 2/3/4 字节。
var partial_packet_base_tick: u64 = 0;
/// 半包起始时的 `poll_invocations`（tick 不前进时仍能丢弃错位半包）。
var partial_packet_start_poll: u64 = 0;
var poll_invocations: u64 = 0;

/// 单轮 `input_hub.pollAll` 内合并相对运动（VirtIO 多包 REL_X/REL_Y），再一次性缩放/入队。
var motion_coalesce_active: bool = false;
var motion_coalesce_dx: i32 = 0;
var motion_coalesce_dy: i32 = 0;
var motion_coalesce_has: bool = false;

var mouse_state: MouseState = .{};
var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;
/// 8042 + PS/2 命令序列已完成（与 io 管理器是否已登记驱动无关）
var hw_initialized: bool = false;
var total_events: u64 = 0;

pub const IOCTL_MOUSE_GET_STATE: u32 = 0x000B0000;
pub const IOCTL_MOUSE_SET_BOUNDS: u32 = 0x000B0004;
pub const IOCTL_MOUSE_GET_EVENTS: u32 = 0x000B0008;
pub const IOCTL_MOUSE_RESET: u32 = 0x000B000C;

fn waitForInput() bool {
    var timeout: u32 = 500_000;
    while (timeout > 0) : (timeout -= 1) {
        if (portio.inb(KB_STATUS_PORT) & 0x01 != 0) return true;
        if (timeout & 0x3FF == 0) portio.ioWait();
    }
    return false;
}

fn waitForOutput() void {
    var timeout: u32 = 500_000;
    while (timeout > 0) : (timeout -= 1) {
        if (portio.inb(KB_STATUS_PORT) & 0x02 == 0) return;
        if (timeout & 0x3FF == 0) portio.ioWait();
    }
}

fn sendCommand(cmd: u8) void {
    waitForOutput();
    portio.outb(KB_CMD_PORT, cmd);
}

fn sendData(data: u8) void {
    waitForOutput();
    portio.outb(KB_DATA_PORT, data);
}

fn readData() u8 {
    if (!waitForInput()) return 0;
    return portio.inb(KB_DATA_PORT);
}

fn mouseWrite(byte: u8) u8 {
    var attempt: u32 = 0;
    while (attempt < 5) : (attempt += 1) {
        sendCommand(0xD4);
        sendData(byte);
        const ack = readData();
        if (ack == 0xFA) return ack;
        if (ack == 0xFE) continue;
        portio.ioWait();
        flush8042Output();
    }
    return 0;
}

/// 键盘方向键 / VirtIO 键盘等注入的相对位移（兜底路径，不依赖 PS/2 鼠标流）。
pub fn injectNudge(dx: i32, dy: i32) void {
    if (dx == 0 and dy == 0) return;
    const cdx = std.math.clamp(dx, -32768, 32767);
    const cdy = std.math.clamp(dy, -32768, 32767);
    mouse_state.x = clampedAddI32(mouse_state.x, cdx);
    mouse_state.y = clampedAddI32(mouse_state.y, cdy);
    clampPosition();
    mouse_state.cursor_moved = true;
    pushEvent(.{
        .dx = @truncate(cdx),
        .dy = @truncate(cdy),
        .buttons = mouse_state.buttons,
    });
}

/// IRQ1/IRQ12：与主循环相同，排空 8042 并路由（见 ke/interrupt.zig）。
pub fn handleIrq() void {
    poll();
}

fn resetPartialIfStale() void {
    if (packet_idx == 0) return;
    const sched = @import("../../ke/scheduler.zig");
    const now = sched.getTicks();
    // ~50ms @100Hz：足够收齐一包，又能从错位中恢复
    if (now > partial_packet_base_tick + 5) {
        packet_idx = 0;
        return;
    }
    // tick 长期为 0 或定时器未走时，仅靠 tick 无法清半包，主循环仍会 poll → 用调用次数兜底
    if (poll_invocations > partial_packet_start_poll + 4096) {
        packet_idx = 0;
    }
}

/// 空闲时轮询 8042 输出缓冲：按 aux 位、半包续包、首字节 PS/2 同步位路由鼠标/键盘。
pub fn poll() void {
    if (builtin.target.cpu.arch != .x86_64) return;
    poll_invocations +%= 1;
    // #region agent log
    if (@import("build_options").agent_ndjson) {
        if (poll_invocations % 4000 == 0) {
            const ag = @import("../../debug/agent_ndjson.zig");
            ag.emit("H5", "mouse.zig:poll", "ps2_poll", "pre", poll_invocations, packet_idx, 0, 0, 0, 0);
        }
    }
    // #endregion
    resetPartialIfStale();
    while (true) {
        const status = portio.inb(KB_STATUS_PORT);
        if (status & 0x01 == 0) return;
        const data = portio.inb(KB_DATA_PORT);
        const aux = (status & 0x20) != 0;
        if (aux) {
            // 8042 已标 aux：允许首字节无 bit3（少数固件/虚拟化与规范不一致）
            processAuxByte(data, true);
        } else if (packet_idx > 0) {
            // 半包已收：后续字节必须进鼠标，否则永远组不齐
            processAuxByte(data, true);
        } else if ((data & 0x08) != 0) {
            // 部分模拟器 aux 位恒为 0；PS/2 鼠标包首字节 bit3 恒为 1
            processAuxByte(data, false);
        } else {
            hal_kbd.handleScancodeByte(data);
        }
    }
}

fn processAuxByte(data: u8, allow_first_without_sync_bit: bool) void {
    resetPartialIfStale();
    if (packet_idx == 0 and (data & 0x08) == 0 and !allow_first_without_sync_bit) return;

    if (packet_idx == 0) {
        partial_packet_base_tick = @import("../../ke/scheduler.zig").getTicks();
        partial_packet_start_poll = poll_invocations;
    }

    packet_buf[packet_idx] = data;
    packet_idx += 1;

    const expected_len: usize = if (has_scroll_wheel) 4 else 3;
    if (packet_idx < expected_len) return;

    packet_idx = 0;

    var event = MouseEvent{};

    event.buttons = packet_buf[0] & 0x07;

    var dx: i16 = @intCast(packet_buf[1]);
    var dy: i16 = @intCast(packet_buf[2]);

    if (packet_buf[0] & 0x10 != 0) dx -= 256;
    if (packet_buf[0] & 0x20 != 0) dy -= 256;

    event.dx = dx;
    event.dy = -dy;

    if (has_scroll_wheel and expected_len == 4) {
        const scroll_raw: i8 = @bitCast(packet_buf[3]);
        event.scroll = scroll_raw;
    }

    deliverMouseEvent(event);
}

fn clampToI32(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn clampedAddI32(a: i32, b: i32) i32 {
    return clampToI32(@as(i64, a) + @as(i64, b));
}

pub fn beginMotionCoalesce() void {
    motion_coalesce_active = true;
    motion_coalesce_dx = 0;
    motion_coalesce_dy = 0;
    motion_coalesce_has = false;
}

fn flushMotionCoalesce() void {
    if (!motion_coalesce_has) return;
    motion_coalesce_has = false;
    const dx = motion_coalesce_dx;
    const dy = motion_coalesce_dy;
    motion_coalesce_dx = 0;
    motion_coalesce_dy = 0;
    deliverMouseEventUncoalesced(.{
        .dx = @truncate(std.math.clamp(dx, -32768, 32767)),
        .dy = @truncate(std.math.clamp(dy, -32768, 32767)),
        .buttons = mouse_state.buttons,
        .scroll = 0,
    });
}

pub fn endMotionCoalesce() void {
    flushMotionCoalesce();
    motion_coalesce_active = false;
}

/// VirtIO-Input / 其它 HID 总线汇总的相对运动（dx、dy 为设备原始增量，语义与 PS/2 包内一致）
pub fn deliverMouseEvent(event: MouseEvent) void {
    if (motion_coalesce_active) {
        if (event.scroll != 0 or event.buttons != mouse_state.buttons) {
            flushMotionCoalesce();
            deliverMouseEventUncoalesced(event);
            return;
        }
        if (event.dx == 0 and event.dy == 0 and event.scroll == 0 and event.buttons == mouse_state.buttons) {
            return;
        }
        motion_coalesce_dx = clampToI32(@as(i64, motion_coalesce_dx) + @as(i64, event.dx));
        motion_coalesce_dy = clampToI32(@as(i64, motion_coalesce_dy) + @as(i64, event.dy));
        motion_coalesce_has = true;
        return;
    }

    deliverMouseEventUncoalesced(event);
}

fn deliverMouseEventUncoalesced(event: MouseEvent) void {
    // 丢弃完全重复的报告（常见于 VirtIO SYN），减轻事件队列与主循环负担。
    if (event.dx == 0 and event.dy == 0 and event.scroll == 0 and event.buttons == mouse_state.buttons) {
        return;
    }

    mouse_state.buttons = event.buttons;
    mouse_state.left_pressed = (event.buttons & 0x01) != 0;
    mouse_state.right_pressed = (event.buttons & 0x02) != 0;
    mouse_state.middle_pressed = (event.buttons & 0x04) != 0;

    var dx_scaled: i32 = @as(i32, event.dx);
    var dy_scaled: i32 = @as(i32, event.dy);

    if (mouse_state.acceleration_enabled) {
        const dx64 = @as(i64, dx_scaled);
        const dy64 = @as(i64, dy_scaled);
        const speed_sq: i128 = @as(i128, dx64) * dx64 + @as(i128, dy64) * dy64;
        const thresh = mouse_state.acceleration_threshold;
        const thresh_sq: i128 = @as(i128, thresh) * thresh;
        if (speed_sq > thresh_sq * 9) {
            dx_scaled = clampToI32(dx64 * 3);
            dy_scaled = clampToI32(dy64 * 3);
        } else if (speed_sq > thresh_sq * 4) {
            dx_scaled = clampToI32(dx64 * 2);
            dy_scaled = clampToI32(dy64 * 2);
        } else if (speed_sq > thresh_sq) {
            dx_scaled = clampToI32(dx64 + @divTrunc(dx64, 2));
            dy_scaled = clampToI32(dy64 + @divTrunc(dy64, 2));
        }
    }

    dx_scaled = clampToI32(@divTrunc(@as(i64, dx_scaled) * @as(i64, mouse_state.sensitivity), 10));
    dy_scaled = clampToI32(@divTrunc(@as(i64, dy_scaled) * @as(i64, mouse_state.sensitivity), 10));
    // 低灵敏度或 @divTrunc 会把 ±1 打成 0，指针表现为「完全不动」
    if (dx_scaled == 0 and event.dx != 0) dx_scaled = std.math.sign(event.dx);
    if (dy_scaled == 0 and event.dy != 0) dy_scaled = std.math.sign(event.dy);

    if (mouse_state.smoothing_enabled) {
        dx_scaled = clampToI32(@divTrunc(@as(i64, dx_scaled) * 3 + @as(i64, mouse_state.prev_dx), 4));
        dy_scaled = clampToI32(@divTrunc(@as(i64, dy_scaled) * 3 + @as(i64, mouse_state.prev_dy), 4));
    }
    mouse_state.prev_dx = dx_scaled;
    mouse_state.prev_dy = dy_scaled;

    mouse_state.velocity_x = dx_scaled;
    mouse_state.velocity_y = dy_scaled;

    if (mouse_state.interpolation_enabled and mouse_state.interpolation_steps > 1) {
        mouse_state.raw_x = clampedAddI32(mouse_state.raw_x, dx_scaled);
        mouse_state.raw_y = clampedAddI32(mouse_state.raw_y, dy_scaled);
        clampRawPosition();

        // i64 差分：极端 clamp/插值状态下 raw 与 display 可能短暂不同向，避免 i32 减法在 Debug 下溢出 panic。
        const rdx = @as(i64, mouse_state.raw_x) - @as(i64, mouse_state.x);
        const rdy = @as(i64, mouse_state.raw_y) - @as(i64, mouse_state.y);
        const st = @as(i64, mouse_state.interpolation_steps);
        mouse_state.sub_x = clampToI32(@divTrunc(rdx, st));
        mouse_state.sub_y = clampToI32(@divTrunc(rdy, st));
        mouse_state.interpolation_idx = mouse_state.interpolation_steps;

        interpolateStep();
    } else {
        mouse_state.x = clampedAddI32(mouse_state.x, dx_scaled);
        mouse_state.y = clampedAddI32(mouse_state.y, dy_scaled);
        mouse_state.raw_x = mouse_state.x;
        mouse_state.raw_y = mouse_state.y;
        clampPosition();
    }

    mouse_state.cursor_moved = true;
    if (@import("build_options").mouse_debug) {
        const md = @import("mouse_debug.zig");
        md.traceAfterDeliver(mouse_state.x, mouse_state.y, event.dx, event.dy, mouse_state.buttons);
    }
    pushEvent(event);
}

fn clampPosition() void {
    const sw = mouse_state.screen_width;
    const sh = mouse_state.screen_height;
    if (sw < 1 or sh < 1) return;
    if (mouse_state.x < 0) mouse_state.x = 0;
    if (mouse_state.y < 0) mouse_state.y = 0;
    if (mouse_state.x >= sw) mouse_state.x = sw - 1;
    if (mouse_state.y >= sh) mouse_state.y = sh - 1;
}

fn clampRawPosition() void {
    const sw = mouse_state.screen_width;
    const sh = mouse_state.screen_height;
    if (sw < 1 or sh < 1) return;
    if (mouse_state.raw_x < 0) mouse_state.raw_x = 0;
    if (mouse_state.raw_y < 0) mouse_state.raw_y = 0;
    if (mouse_state.raw_x >= sw) mouse_state.raw_x = sw - 1;
    if (mouse_state.raw_y >= sh) mouse_state.raw_y = sh - 1;
}

pub fn interpolateStep() void {
    if (mouse_state.interpolation_idx == 0) return;

    if (mouse_state.interpolation_idx == 1) {
        mouse_state.x = mouse_state.raw_x;
        mouse_state.y = mouse_state.raw_y;
    } else {
        mouse_state.x = clampedAddI32(mouse_state.x, mouse_state.sub_x);
        mouse_state.y = clampedAddI32(mouse_state.y, mouse_state.sub_y);
    }

    clampPosition();
    mouse_state.interpolation_idx -= 1;
    // cursor_moved 仅由 IRQ 数据包设置；此处不置位，避免同一帧内多次触发全屏重绘
}

pub fn isInterpolating() bool {
    return mouse_state.interpolation_idx > 0;
}

pub fn hasCursorMoved() bool {
    return mouse_state.cursor_moved;
}

pub fn clearCursorMoved() void {
    mouse_state.cursor_moved = false;
}

pub fn setSensitivity(sens: i32) void {
    mouse_state.sensitivity = if (sens < 1) 1 else if (sens > 20) 20 else sens;
}

pub fn setAcceleration(enabled: bool, threshold: i32) void {
    mouse_state.acceleration_enabled = enabled;
    mouse_state.acceleration_threshold = threshold;
}

pub fn setInterpolation(enabled: bool, steps: u8) void {
    mouse_state.interpolation_enabled = enabled;
    mouse_state.interpolation_steps = if (steps < 1) 1 else if (steps > 8) 8 else steps;
}

pub fn setSmoothing(enabled: bool) void {
    mouse_state.smoothing_enabled = enabled;
}

fn pushEvent(event: MouseEvent) void {
    const next = (queue_head + 1) % EVENT_QUEUE_SIZE;
    if (next == queue_tail) {
        queue_tail = (queue_tail + 1) % EVENT_QUEUE_SIZE;
    }
    event_queue[queue_head] = event;
    queue_head = next;
    total_events += 1;
}

pub fn popEvent() ?MouseEvent {
    if (queue_head == queue_tail) return null;
    const event = event_queue[queue_tail];
    queue_tail = (queue_tail + 1) % EVENT_QUEUE_SIZE;
    return event;
}

pub fn hasEvents() bool {
    return queue_head != queue_tail;
}

pub fn getState() *const MouseState {
    return &mouse_state;
}

pub fn setScreenBounds(width: i32, height: i32) void {
    const w = if (width < 1) 1 else width;
    const h = if (height < 1) 1 else height;
    mouse_state.screen_width = w;
    mouse_state.screen_height = h;
    clampPosition();
}

pub fn setPosition(x: i32, y: i32) void {
    mouse_state.x = x;
    mouse_state.y = y;
    mouse_state.raw_x = x;
    mouse_state.raw_y = y;
    mouse_state.interpolation_idx = 0;
    mouse_state.sub_x = 0;
    mouse_state.sub_y = 0;
    mouse_state.prev_dx = 0;
    mouse_state.prev_dy = 0;
    clampPosition();
    mouse_state.raw_x = mouse_state.x;
    mouse_state.raw_y = mouse_state.y;
}

pub fn getX() i32 {
    return mouse_state.x;
}

pub fn getY() i32 {
    return mouse_state.y;
}

/// 当前指针钳位用的逻辑宽度（与 `setScreenBounds` / 桌面 GOP 一致）。
pub fn getScreenWidth() i32 {
    return mouse_state.screen_width;
}

/// 当前指针钳位用的逻辑高度。
pub fn getScreenHeight() i32 {
    return mouse_state.screen_height;
}

pub fn isLeftPressed() bool {
    return mouse_state.left_pressed;
}

pub fn isRightPressed() bool {
    return mouse_state.right_pressed;
}

fn mouseDispatch(irp: *io.Irp) io.NTSTATUS {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        .ioctl => return handleIoctl(irp),
        .read => {
            if (popEvent()) |event| {
                irp.buffer_ptr = @as(u64, @intCast(@as(u32, @bitCast([2]u16{ @bitCast(event.dx), @bitCast(event.dy) }))));
                irp.bytes_transferred = @intCast(event.buttons);
                irp.complete(io.STATUS_SUCCESS, 1);
            } else {
                irp.complete(io.STATUS_SUCCESS, 0);
            }
            return io.STATUS_SUCCESS;
        },
        else => {
            irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
            return io.STATUS_NOT_IMPLEMENTED;
        },
    }
}

fn handleIoctl(irp: *io.Irp) io.NTSTATUS {
    switch (irp.ioctl_code) {
        IOCTL_MOUSE_GET_STATE => {
            irp.buffer_ptr = @bitCast([2]u32{
                @bitCast(mouse_state.x),
                @bitCast(mouse_state.y),
            });
            irp.bytes_transferred = mouse_state.buttons;
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        IOCTL_MOUSE_SET_BOUNDS => {
            const w: i32 = @intCast(@as(u32, @truncate(irp.buffer_ptr & 0xFFFF)));
            const h: i32 = @intCast(@as(u32, @truncate((irp.buffer_ptr >> 16) & 0xFFFF)));
            setScreenBounds(w, h);
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        IOCTL_MOUSE_RESET => {
            const sw = mouse_state.screen_width;
            const sh = mouse_state.screen_height;
            queue_head = 0;
            queue_tail = 0;
            packet_idx = 0;
            mouse_state = .{};
            mouse_state.screen_width = sw;
            mouse_state.screen_height = sh;
            mouse_state.x = @divTrunc(sw, 2);
            mouse_state.y = @divTrunc(sh, 2);
            mouse_state.raw_x = mouse_state.x;
            mouse_state.raw_y = mouse_state.y;
            irp.complete(io.STATUS_SUCCESS, 0);
            return io.STATUS_SUCCESS;
        },
        else => {
            irp.complete(io.STATUS_NOT_IMPLEMENTED, 0);
            return io.STATUS_NOT_IMPLEMENTED;
        },
    }
}

pub fn isInitialized() bool {
    return driver_initialized;
}

pub fn isHardwareInitialized() bool {
    return hw_initialized;
}

/// 图形桌面就绪后再次打开数据流（长时间引导后部分固件/模拟器需重使能）。
pub fn reassertStreamEnable() void {
    if (builtin.target.cpu.arch != .x86_64) return;
    if (!hw_initialized) return;
    packet_idx = 0;
    _ = mouseWrite(0xF4);
}

pub fn getTotalEvents() u64 {
    return total_events;
}

fn flush8042Output() void {
    var guard: u32 = 0;
    while (guard < 16) : (guard += 1) {
        const st = portio.inb(KB_STATUS_PORT);
        if (st & 0x01 == 0) return;
        _ = portio.inb(KB_DATA_PORT);
    }
}

/// 复位/探测后控制器里可能仍有 BAT、ACK、旧包残留；多读几次避免首包错位。
fn flush8042OutputDeep() void {
    var guard: u32 = 0;
    while (guard < 256) : (guard += 1) {
        const st = portio.inb(KB_STATUS_PORT);
        if (st & 0x01 == 0) return;
        _ = portio.inb(KB_DATA_PORT);
    }
}

/// 采样率命令：F3 后紧跟速率字节（OSDev PS/2 mouse）。
fn setMouseSampleRate(rate: u8) void {
    _ = mouseWrite(0xF3);
    _ = mouseWrite(rate);
    portio.ioWait();
}

/// IntelliMouse 滚轮探测：200→100→80 后 F2；若 id 为 0x03/0x04 则设备发 4 字节包。
fn probeIntelliMouseId() u8 {
    setMouseSampleRate(200);
    setMouseSampleRate(100);
    setMouseSampleRate(80);
    _ = mouseWrite(0xF2);
    portio.ioWait();
    return readData();
}

/// 8042 + PS/2 鼠标硬件初始化（须在 PIC 解掩码 / sti 之前调用）。可早于 `io.init()`。
pub fn initHardware() void {
    if (builtin.target.cpu.arch != .x86_64) return;
    if (hw_initialized) return;

    packet_idx = 0;
    flush8042Output();

    sendCommand(0xA8);
    portio.ioWait();

    sendCommand(0x20);
    portio.ioWait();
    const config = readData();
    // OSDev 8042：bit0/1=键鼠中断 bit4/5=键鼠口使能；bit7 保留须为 0。
    const new_config = (config | 0x03 | 0x10 | 0x20) & 0x7F;
    sendCommand(0x60);
    sendData(new_config);
    portio.ioWait();
    flush8042Output();

    // 软复位：若 ACK 异常则跳过复位字节读取，避免卡在半初始化状态
    const rst_ack = mouseWrite(0xFF);
    if (rst_ack == 0xFA) {
        portio.ioWait();
        _ = readData();
        _ = readData();
        flush8042OutputDeep();
    } else {
        flush8042OutputDeep();
    }

    _ = mouseWrite(0xF6);
    flush8042Output();

    _ = mouseWrite(0xF2);
    portio.ioWait();
    var mouse_id = readData();

    has_scroll_wheel = false;
    if (mouse_id == 0x03 or mouse_id == 0x04) {
        // 已是滚轮 ID：再跑一遍魔法序列，使 4 字节流与 ID 一致（见 OSDev IntelliMouse）
        mouse_id = probeIntelliMouseId();
        has_scroll_wheel = (mouse_id == 0x03 or mouse_id == 0x04);
        if (!has_scroll_wheel) {
            _ = mouseWrite(0xF6);
            flush8042Output();
        }
    } else if (mouse_id == 0x00 or mouse_id == 0xFF) {
        // 标准鼠标或读失败：尝试升级为滚轮协议
        const wid = probeIntelliMouseId();
        mouse_id = wid;
        has_scroll_wheel = (wid == 0x03 or wid == 0x04);
        if (!has_scroll_wheel) {
            _ = mouseWrite(0xF6);
            flush8042Output();
        }
    }

    _ = mouseWrite(0xF4);

    mouse_state.x = @divTrunc(mouse_state.screen_width, 2);
    mouse_state.y = @divTrunc(mouse_state.screen_height, 2);
    mouse_state.raw_x = mouse_state.x;
    mouse_state.raw_y = mouse_state.y;

    hw_initialized = true;
    packet_idx = 0;

    klog.info("Mouse: PS/2 ready (id=0x%x, %u-byte packets, relaxed aux sync)", .{
        mouse_id, if (has_scroll_wheel) @as(u8, 4) else @as(u8, 3),
    });
}

/// 在 `io.init()` 之后登记 \\Driver\\Mouse（`io.init()` 会清空驱动表，须晚于硬件 init 再注册）。
/// 非 x86 无 PS/2 包，但 VirtIO-Input 仍通过本驱动的状态与事件队列上报指针运动。
pub fn registerWithIo() void {
    if (driver_initialized) return;

    driver_idx = io.registerDriver("\\Driver\\Mouse", mouseDispatch) orelse {
        klog.err("Mouse: Failed to register driver", .{});
        return;
    };

    device_idx = io.createDevice("\\Device\\Mouse0", .mouse, driver_idx) orelse {
        klog.err("Mouse: Failed to create device", .{});
        return;
    };

    driver_initialized = true;
    klog.info("Mouse: class driver registered (\\Device\\Mouse0)", .{});
}

/// 从 `HKCU\Control Panel\Mouse` 同步灵敏度/加速（`registry.init()` 之后可再次调用，例如用户态改键后）。
/// Ref: https://learn.microsoft.com/windows/win32/inputdev/mouse-input（用户输入概念）；注册表值名为常见 OEM/Shell 约定，非抄表。
pub fn syncFromRegistry() void {
    const reg = @import("../../registry/registry.zig");
    if (reg.hkcu_control_panel_mouse_key) |k| {
        if (reg.queryValueDword(k, "MouseSensitivity")) |v| {
            if (v >= 1 and v <= 20) setSensitivity(@intCast(v));
        }
        if (reg.queryValueDword(k, "MouseThreshold1")) |v| {
            const th: i32 = @intCast(@min(v, 64));
            setAcceleration(mouse_state.acceleration_enabled, th);
        }
        if (reg.queryValueDword(k, "DoubleClickSpeed")) |v| {
            if (v >= 100 and v <= 1000) mouse_state.double_click_time_ms = v;
        }
        if (reg.queryValueDword(k, "DoubleClickWidth")) |w| {
            if (w >= 1 and w <= 64) mouse_state.double_click_width = w;
        }
        if (reg.queryValueDword(k, "DoubleClickHeight")) |h| {
            if (h >= 1 and h <= 64) mouse_state.double_click_height = h;
        }
    }
}

pub fn init() void {
    initHardware();
    registerWithIo();
    syncFromRegistry();
}
