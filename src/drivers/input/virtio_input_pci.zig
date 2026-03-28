//! VirtIO Input PCI（QEMU `virtio-mouse-pci` / `virtio-tablet-pci` / `virtio-keyboard-pci`，均为 1af4:1052）
//! 现代 VirtIO 1.0 传输 + 事件队列轮询；支持最多 MAX_INST 个 PCI 实例（键鼠/平板等）。
//! 参考：VirtIO 1.2 §5.4 Input、§4.1.4 Virtio PCI。

const builtin = @import("builtin");
const std = @import("std");
const pcie = @import("../bus/pcie.zig");
const vm = @import("../../mm/vm.zig");
const klog = @import("../../rtl/klog.zig");
const mouse = @import("mouse.zig");
const evdev = @import("evdev_virtio_bridge.zig");

const VIRTIO_VENDOR: u16 = 0x1AF4;
const VIRTIO_DEV_INPUT: u16 = 0x1052;
const VIRTIO_PCI_CAP: u8 = 0x09;
const VIRTIO_PCI_CAP_COMMON_CFG: u8 = 1;
const VIRTIO_PCI_CAP_NOTIFY_CFG: u8 = 2;
const VIRTIO_PCI_CAP_ISR_CFG: u8 = 3;

const VRING_DESC_F_WRITE: u16 = 2;

const EV_SYN: u16 = 0x0000;
const EV_KEY: u16 = 0x0001;
const EV_REL: u16 = 0x0002;
const EV_ABS: u16 = 0x0003;
const ABS_X: u16 = 0x0000;
const ABS_Y: u16 = 0x0001;
const REL_X: u16 = 0x0000;
const REL_Y: u16 = 0x0001;
const REL_WHEEL: u16 = 0x0008;
const BTN_LEFT: u16 = 0x0110;
const BTN_RIGHT: u16 = 0x0111;
const BTN_MIDDLE: u16 = 0x0112;

/// QEMU `virtio-tablet` 等常见 ABS 上界（Linux evdev 惯例）；无能力查询时的默认标度。
const ABS_AXIS_MAX_DEFAULT: i32 = 32767;

const VIRTIO_F_VERSION_1: u32 = 1;

const STATUS_ACK: u8 = 1;
const STATUS_DRIVER: u8 = 2;
const STATUS_DRIVER_OK: u8 = 4;
const STATUS_FEATURES_OK: u8 = 8;
const STATUS_FAILED: u8 = 128;

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

/// mouse + keyboard + tablet（QEMU 可挂多个 1af4:1052）
const MAX_INST: usize = 4;
const LINUX_INPUT_EVENT_SZ: u32 = 8;
/// QEMU virtio_input_send：SYN_REPORT 前对每个排队事件各 virtqueue_pop 一次；仅 1 个 avail 缓冲时第二次 pop 失败则整批丢弃（H6：used 永 0）。
const RECV_BYTES_PER_DESC: u32 = LINUX_INPUT_EVENT_SZ;

const VirtioInputInst = struct {
    active: bool = false,
    common_base: usize = 0,
    notify_base: usize = 0,
    notify_mult: u32 = 0,
    isr_base: usize = 0,
    queue_notify_off: u16 = 0,
    queue_size: u16 = 0,
    ring_page: [4096]u8 align(4096) = undefined,
    /// ring_page 内 recv 小槽起始（每描述符 8B，共 queue_size 槽，与描述符表一一对应）
    event_slot_off: usize = 0,
    desc_off: usize = 0,
    avail_off: usize = 0,
    used_off: usize = 0,
    last_used_idx: u16 = 0,
    local_avail_idx: u16 = 0,
    hid_buttons: u8 = 0,
    acc_dx: i32 = 0,
    acc_dy: i32 = 0,
    acc_scroll: i32 = 0,
    /// virtio-tablet-pci：QEMU GTK 常发 ABS 而非 REL；与未抓取时的 virtio-mouse 互补。
    tab_have_x: bool = false,
    tab_have_y: bool = false,
    tab_x: i32 = 0,
    tab_y: i32 = 0,
    /// 本 SYN 报告周期内收到过 ABS 轴更新（在 EV_SYN 上映射到像素位移）。
    abs_frame_dirty: bool = false,
    /// 本 PCI 实例是否发过指针类事件（REL/ABS 坐标/鼠标键）；纯键盘实例的空 SYN 不调用 mouse.deliver。
    has_pointer_ev: bool = false,
};

var instances: [MAX_INST]VirtioInputInst = [_]VirtioInputInst{.{}} ** MAX_INST;

fn fullMemoryFence() void {
    switch (builtin.target.cpu.arch) {
        .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dsb sy" ::: .{ .memory = true }),
        .riscv64 => asm volatile ("fence rw, rw" ::: .{ .memory = true }),
        .loongarch64 => asm volatile ("dbar 0" ::: .{ .memory = true }),
        else => asm volatile ("" ::: .{ .memory = true }),
    }
}

fn mmio_w8(base: usize, off: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(base + off)).* = v;
}

fn mmio_r8(base: usize, off: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(base + off)).*;
}

fn mmio_w16(base: usize, off: usize, v: u16) void {
    @as(*volatile u16, @ptrFromInt(base + off)).* = v;
}

fn mmio_r16(base: usize, off: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(base + off)).*;
}

fn mmio_w32(base: usize, off: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(base + off)).* = v;
}

fn mmio_r32(base: usize, off: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(base + off)).*;
}

fn pciReadLe32(loc: pcie.PciLoc, off: u16) u32 {
    var v: u32 = 0;
    var i: u16 = 0;
    while (i < 4) : (i += 1) {
        const sh: u5 = @intCast(i * 8);
        v |= @as(u32, pcie.readConfigByte(loc.bus, loc.dev, loc.func, off + i)) << sh;
    }
    return v;
}

/// VirtIO PCI MMIO BAR（含 64-bit type=0b10）；仅 32-bit 时与旧 `barPhys32` 行为一致。
fn barMmioPhys(loc: pcie.PciLoc, idx: u8) ?u64 {
    const raw = pcie.readConfigDword(loc.bus, loc.dev, loc.func, @as(u16, 0x10) + @as(u16, idx) * 4);
    if (raw == 0xFFFFFFFF) return null;
    if ((raw & 1) != 0) return null;
    const typ = (raw >> 1) & 3;
    if (typ == 2) {
        const hi = pcie.readConfigDword(loc.bus, loc.dev, loc.func, @as(u16, 0x10) + @as(u16, idx + 1) * 4);
        return (@as(u64, hi) << 32) | (@as(u64, raw) & 0xFFFF_FFF0);
    }
    return @as(u64, raw) & 0xFFFF_FFF0;
}

fn mapBarIfNeeded(phys: u64) bool {
    if (phys == 0) return false;
    return vm.mapDeviceMmioIdentity(phys, 0x10000);
}

/// LoongArch：VA≠GPA 时须非缓存 + 正确 GPA（H7）。x86_64 等：部分 QEMU/TCG 路径下 PCI DMA 回填的 used 环与 CPU D-cache 可能不一致，读 used.idx 长期停滞则鼠标无位移（与 H6 同类）。
fn remapInstQueueDmaUncached(inst: *VirtioInputInst) void {
    const need_uncached = builtin.target.cpu.arch == .loongarch64 or builtin.target.cpu.arch == .x86_64;
    if (!need_uncached) return;
    const ps: usize = @import("../../arch.zig").impl.paging.page_size;
    const r0 = @intFromPtr(&inst.ring_page);
    const r1 = r0 + inst.ring_page.len;
    var v = r0 & ~(ps - 1);
    while (v < r1) : (v += ps) {
        if (!vm.remapIdentityVirtPageUncached(v)) {
            klog.warn("VirtIO-Input: DMA remap uncached failed va=0x%x", .{v});
        }
    }
}

fn readUsedIdx(inst: *VirtioInputInst) u16 {
    const p = @intFromPtr(&inst.ring_page) + inst.used_off;
    return @as(*volatile u16, @ptrFromInt(p + 2)).*;
}

fn readAvailIdxWrite(inst: *VirtioInputInst, val: u16) void {
    const p = @intFromPtr(&inst.ring_page) + inst.avail_off;
    @as(*volatile u16, @ptrFromInt(p + 2)).* = val;
}

fn readAvailIdxRead(inst: *VirtioInputInst) u16 {
    const p = @intFromPtr(&inst.ring_page) + inst.avail_off;
    return @as(*volatile u16, @ptrFromInt(p + 2)).*;
}

fn availRingIndex(inst: *VirtioInputInst, i: u16) *volatile u16 {
    const p = @intFromPtr(&inst.ring_page) + inst.avail_off + 4 + @as(usize, @intCast(i)) * 2;
    return @as(*volatile u16, @ptrFromInt(p));
}

fn usedRingElem(inst: *VirtioInputInst, i: u16) struct { id: u32, len: u32 } {
    const qs = inst.queue_size;
    if (qs == 0) return .{ .id = 0, .len = 0 };
    const p = @intFromPtr(&inst.ring_page) + inst.used_off + 4 + @as(usize, @intCast(@as(u32, i) % @as(u32, qs))) * 8;
    const id = @as(*volatile u32, @ptrFromInt(p)).*;
    const ln = @as(*volatile u32, @ptrFromInt(p + 4)).*;
    return .{ .id = id, .len = ln };
}

fn descTable(inst: *VirtioInputInst) [*]VirtqDesc {
    return @as([*]VirtqDesc, @ptrFromInt(@intFromPtr(&inst.ring_page) + inst.desc_off));
}

/// 将 evdev ABS 值映射到像素坐标 [0 .. extent-1]（VirtIO Input / QEMU tablet 常用 0..32767）。
fn mapAbsToPixel(abs_val: i32, extent_px: i32) i32 {
    if (extent_px <= 1) return 0;
    const maxv: i32 = ABS_AXIS_MAX_DEFAULT;
    const v = std.math.clamp(abs_val, 0, maxv);
    // `extent_px - 1` 在 i32 上若遇异常 extent 可能 Debug 溢出；用 i64 与 `framebuffer`/`material` 注释同源。
    const ext1 = @as(i64, extent_px) - 1;
    const num = @as(i64, v) * ext1;
    const den = @as(i64, maxv);
    return @intCast(@divTrunc(num, den));
}

fn kickQueue0(inst: *VirtioInputInst) void {
    if (inst.notify_base == 0) return;
    // 部分实现以 common_cfg.queue_select 解释门铃；notify 前固定选中队列 0（evt）。
    mmio_w16(inst.common_base, 0x16, 0);
    fullMemoryFence();
    // VirtIO 1.x PCI：notify_off_multiplier==0 时所有队列共用 notifications 区起始地址（不得乘 queue_notify_off）。
    const port: usize = if (inst.notify_mult == 0)
        inst.notify_base
    else
        inst.notify_base + @as(usize, inst.notify_mult) * @as(usize, inst.queue_notify_off);
    // Linux vp_notify：向映射的 notify 端口写入队列索引（队列 0 → 0）。
    @as(*volatile u16, @ptrFromInt(port)).* = 0;
}

fn syncDeliver(inst: *VirtioInputInst) void {
    if (inst.abs_frame_dirty) {
        if (inst.tab_have_x and inst.tab_have_y) {
            const sw = mouse.getScreenWidth();
            const sh = mouse.getScreenHeight();
            if (sw > 0 and sh > 0) {
                const px = mapAbsToPixel(inst.tab_x, sw);
                const py = mapAbsToPixel(inst.tab_y, sh);
                const adx = @as(i64, px) - @as(i64, mouse.getX());
                const ady = @as(i64, py) - @as(i64, mouse.getY());
                const sx = @as(i64, inst.acc_dx) + adx;
                const sy = @as(i64, inst.acc_dy) + ady;
                inst.acc_dx = @intCast(std.math.clamp(sx, -32768, 32767));
                inst.acc_dy = @intCast(std.math.clamp(sy, -32768, 32767));
            }
        }
        inst.abs_frame_dirty = false;
    }

    const idle = inst.acc_dx == 0 and inst.acc_dy == 0 and inst.acc_scroll == 0 and inst.hid_buttons == 0;
    if (idle and !inst.has_pointer_ev) return;

    if (@import("build_options").mouse_debug) {
        @import("mouse_debug.zig").noteVirtioSyncDeliver();
    }
    const ev = mouse.MouseEvent{
        .dx = @truncate(std.math.clamp(inst.acc_dx, -32768, 32767)),
        .dy = @truncate(std.math.clamp(inst.acc_dy, -32768, 32767)),
        .buttons = inst.hid_buttons,
        .scroll = @truncate(std.math.clamp(inst.acc_scroll, -128, 127)),
    };
    mouse.deliverMouseEvent(ev);
    inst.acc_dx = 0;
    inst.acc_dy = 0;
    inst.acc_scroll = 0;
    inst.has_pointer_ev = false;
}

fn parseLinuxInput(inst: *VirtioInputInst, le_pkt: *const [LINUX_INPUT_EVENT_SZ]u8) void {
    const typ = @as(u16, le_pkt[0]) | (@as(u16, le_pkt[1]) << 8);
    const code = @as(u16, le_pkt[2]) | (@as(u16, le_pkt[3]) << 8);
    // Linux input_event.value 为 little-endian **有符号** i32；先组 u32 再 @bitCast，禁止 @intCast(u32→i32)（负增量如 REL_X=-1 会 panic）
    const val_le: u32 = @as(u32, le_pkt[4]) |
        (@as(u32, le_pkt[5]) << 8) |
        (@as(u32, le_pkt[6]) << 16) |
        (@as(u32, le_pkt[7]) << 24);
    const val: i32 = @bitCast(val_le);

    switch (typ) {
        EV_REL => {
            if (code == REL_X or code == REL_Y or code == REL_WHEEL) {
                inst.has_pointer_ev = true;
            }
            // REL_X/Y：立即上报位移，不依赖 EV_SYN。部分 QEMU/virtqueue 路径下 SYN 批处理延迟或异常时，
            // 仅累加 acc_* 会导致指针长期不动；SYN 上 acc 已为 0，deliverMouseEvent 会按重复包丢弃。
            if (code == REL_X) {
                mouse.deliverMouseEvent(.{
                    .dx = @truncate(std.math.clamp(val, -32768, 32767)),
                    .dy = 0,
                    .buttons = inst.hid_buttons,
                    .scroll = 0,
                });
            } else if (code == REL_Y) {
                mouse.deliverMouseEvent(.{
                    .dx = 0,
                    .dy = @truncate(std.math.clamp(val, -32768, 32767)),
                    .buttons = inst.hid_buttons,
                    .scroll = 0,
                });
            } else if (code == REL_WHEEL) {
                const sum = @as(i64, inst.acc_scroll) + @as(i64, val);
                inst.acc_scroll = @intCast(std.math.clamp(sum, std.math.minInt(i32), std.math.maxInt(i32)));
            }
        },
        EV_ABS => {
            // 平板 ABS 为「设备归一化坐标」，须在 EV_SYN 时按当前屏大小映射为像素再求位移（勿把原始 ABS 差分当像素）。
            if (code == ABS_X) {
                inst.has_pointer_ev = true;
                inst.abs_frame_dirty = true;
                inst.tab_x = val;
                inst.tab_have_x = true;
            } else if (code == ABS_Y) {
                inst.has_pointer_ev = true;
                inst.abs_frame_dirty = true;
                inst.tab_y = val;
                inst.tab_have_y = true;
            }
        },
        EV_KEY => {
            if (code == BTN_LEFT) {
                inst.has_pointer_ev = true;
                if (val != 0) inst.hid_buttons |= 1 else inst.hid_buttons &= ~@as(u8, 1);
                mouse.deliverMouseEvent(.{ .dx = 0, .dy = 0, .buttons = inst.hid_buttons, .scroll = 0 });
            } else if (code == BTN_RIGHT) {
                inst.has_pointer_ev = true;
                if (val != 0) inst.hid_buttons |= 2 else inst.hid_buttons &= ~@as(u8, 2);
                mouse.deliverMouseEvent(.{ .dx = 0, .dy = 0, .buttons = inst.hid_buttons, .scroll = 0 });
            } else if (code == BTN_MIDDLE) {
                inst.has_pointer_ev = true;
                if (val != 0) inst.hid_buttons |= 4 else inst.hid_buttons &= ~@as(u8, 4);
                mouse.deliverMouseEvent(.{ .dx = 0, .dy = 0, .buttons = inst.hid_buttons, .scroll = 0 });
            } else {
                evdev.handleEvKey(code, val);
            }
        },
        EV_SYN => {
            syncDeliver(inst);
        },
        else => {},
    }
}

/// 将描述符还回 avail 并通知设备。QEMU virtio-input 依赖每次回收后的 queue notify 才会继续填充缓冲区；批量只 kick 一次会导致环停滞、指针无位移。
fn submitRecvSlot(inst: *VirtioInputInst, desc_idx: u16) void {
    const qs = inst.queue_size;
    if (qs == 0) return;
    const i = inst.local_avail_idx % qs;
    availRingIndex(inst, i).* = desc_idx;
    inst.local_avail_idx +%= 1;
    readAvailIdxWrite(inst, inst.local_avail_idx);
    fullMemoryFence();
    kickQueue0(inst);
}

fn failDevice(inst: *VirtioInputInst, st: u8) void {
    mmio_w8(inst.common_base, 0x14, st | STATUS_FAILED);
    inst.active = false;
    klog.warn("VirtIO-Input: init failed (status 0x%x)", .{st});
}

fn pollOne(inst: *VirtioInputInst, inst_i: u8) void {
    if (!inst.active) return;
    const qs: u32 = inst.queue_size;
    if (qs == 0) return;

    if (inst.isr_base != 0) {
        _ = mmio_r8(inst.isr_base, 0);
    }

    // 每轮重读 used.idx；勿在热路径写串口（agent_ndjson），否则易与 QEMU 串口背压叠加成假死。
    // qs*128 用 u64 再饱和到 u32，避免异常/损坏 queue_size 在 Debug 下触发 u32 乘法 integer overflow。
    const prod64 = @as(u64, qs) *% 128;
    const capped: u32 = @intCast(@min(prod64, @as(u64, std.math.maxInt(u32))));
    const max_iters: u32 = @max(128, capped);
    var iter: u32 = 0;
    while (iter < max_iters) : (iter += 1) {
        fullMemoryFence();
        const used_idx = readUsedIdx(inst);
        if (@import("build_options").mouse_debug and iter == 0) {
            @import("mouse_debug.zig").snapshotVirtio(inst_i, true, used_idx, inst.last_used_idx);
        }
        if (inst.last_used_idx == used_idx) break;

        fullMemoryFence();
        const elem = usedRingElem(inst, inst.last_used_idx);
        fullMemoryFence();
        if (elem.len >= LINUX_INPUT_EVENT_SZ) {
            const di = @as(usize, @intCast(elem.id % @as(u32, @intCast(inst.queue_size))));
            const base = inst.event_slot_off + di * @as(usize, @intCast(RECV_BYTES_PER_DESC));
            const cap = @min(elem.len, RECV_BYTES_PER_DESC);
            var off: u32 = 0;
            while (off + LINUX_INPUT_EVENT_SZ <= cap) : (off += LINUX_INPUT_EVENT_SZ) {
                parseLinuxInput(inst, inst.ring_page[base + @as(usize, off) ..][0..LINUX_INPUT_EVENT_SZ]);
            }
        }
        inst.last_used_idx +%= 1;
        submitRecvSlot(inst, @truncate(elem.id));
    }
}

pub fn poll() void {
    if (!pcie.supports_pci_config) return;
    // 两轮：一批 used 元数据在处理中途可见时，第二轮可继续排空，减少跨主循环 tick 的阶跃。
    for (0..2) |_| {
        for (&instances, 0..) |*inst, j| {
            pollOne(inst, @truncate(j));
        }
    }
}

fn virtioAttachModern(inst: *VirtioInputInst, loc: pcie.PciLoc) bool {
    inst.* = .{};
    var common_bar: u8 = 0xFF;
    var common_off: u32 = 0;
    var notify_bar: u8 = 0xFF;
    var notify_off: u32 = 0;
    var isr_bar: u8 = 0xFF;
    var isr_off: u32 = 0;
    var notify_mult_local: u32 = 0;

    const st_word = pcie.readConfigDword(loc.bus, loc.dev, loc.func, 0x04);
    const status_hi: u16 = @truncate(st_word >> 16);
    if ((status_hi & 0x10) == 0) return false;

    var cap_ptr: u16 = pcie.readConfigByte(loc.bus, loc.dev, loc.func, 0x34);
    while (cap_ptr != 0) {
        const cap_id = pcie.readConfigByte(loc.bus, loc.dev, loc.func, cap_ptr);
        const next = pcie.readConfigByte(loc.bus, loc.dev, loc.func, cap_ptr + 1);
        const cap_len = pcie.readConfigByte(loc.bus, loc.dev, loc.func, cap_ptr + 2);
        if (cap_id == VIRTIO_PCI_CAP and cap_len >= 16) {
            const cfg_t = pcie.readConfigByte(loc.bus, loc.dev, loc.func, cap_ptr + 3);
            const bar = pcie.readConfigByte(loc.bus, loc.dev, loc.func, cap_ptr + 4);
            const off = pciReadLe32(loc, cap_ptr + 8);
            _ = pciReadLe32(loc, cap_ptr + 12);
            switch (cfg_t) {
                VIRTIO_PCI_CAP_COMMON_CFG => {
                    common_bar = bar;
                    common_off = off;
                },
                VIRTIO_PCI_CAP_NOTIFY_CFG => {
                    notify_bar = bar;
                    notify_off = off;
                    if (cap_len >= 20) {
                        notify_mult_local = pciReadLe32(loc, cap_ptr + 16);
                    }
                },
                VIRTIO_PCI_CAP_ISR_CFG => {
                    isr_bar = bar;
                    isr_off = off;
                },
                else => {},
            }
        }
        cap_ptr = next;
    }

    if (common_bar >= 6 or notify_bar >= 6) return false;
    // 保留 cap 中的 0：与 kickQueue0 中「mult==0 → 仅写 notify_base」一致（勿擅自改成 4，会敲错门铃）。

    const b_phys_c = barMmioPhys(loc, common_bar) orelse return false;
    const b_phys_n = barMmioPhys(loc, notify_bar) orelse return false;
    if (!mapBarIfNeeded(b_phys_c)) return false;
    if (b_phys_n != b_phys_c) {
        if (!mapBarIfNeeded(b_phys_n)) return false;
    }

    inst.common_base = @intCast(b_phys_c + common_off);
    inst.notify_base = @intCast(b_phys_n + notify_off);
    inst.notify_mult = notify_mult_local;

    if (isr_bar < 6) {
        if (barMmioPhys(loc, isr_bar)) |bp| {
            if (mapBarIfNeeded(bp)) {
                inst.isr_base = @intCast(bp + isr_off);
            }
        }
    }

    mmio_w8(inst.common_base, 0x14, 0);
    mmio_w8(inst.common_base, 0x14, STATUS_ACK | STATUS_DRIVER);

    mmio_w32(inst.common_base, 0x0, 1);
    const dev_hi = mmio_r32(inst.common_base, 0x4);
    if ((dev_hi & VIRTIO_F_VERSION_1) != 0) {
        mmio_w32(inst.common_base, 0x8, 1);
        mmio_w32(inst.common_base, 0xc, VIRTIO_F_VERSION_1);
    }

    mmio_w8(inst.common_base, 0x14, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK);
    const st = mmio_r8(inst.common_base, 0x14);
    if ((st & STATUS_FEATURES_OK) == 0) {
        failDevice(inst, st);
        return false;
    }

    mmio_w16(inst.common_base, 0x16, 0);
    // 勿向 queue_enable(0x1c) 写 0：QEMU hw/virtio/virtio-pci.c 仅接受写 1，写 0 会 virtio_error
    //（串口可见 "wrong value for queue_enable 0"），并可能把设备置于错误态。冷启动队列本为未启用，
    // 与 Linux setup_vq 一致：直接读 max queue_size、写 ring、再 queue_enable=1。若遇残留已启用，
    // 应协商 VIRTIO_F_RING_RESET 后写 queue_reset(0x3a)，而非写 enable=0。
    fullMemoryFence();
    const qs = mmio_r16(inst.common_base, 0x18);
    if (qs < 2 or qs > 256) {
        failDevice(inst, mmio_r8(inst.common_base, 0x14));
        return false;
    }
    inst.queue_size = @min(qs, 16);
    // VirtIO 1.x：须把驱动实际使用的队列深度写回 0x18，否则设备仍按最大深度（如 128）索引环，
    // 与 ring_page 内按 16 槽布局不一致，表现为 used 环永远对不上、鼠标无事件。
    mmio_w16(inst.common_base, 0x18, inst.queue_size);
    // 未启用 MSI-X 时必须写 NO_VECTOR，否则部分固件/模拟器对队列向量 0 的处理会导致设备不投递。
    mmio_w16(inst.common_base, 0x1a, 0xFFFF);

    inst.desc_off = 0;
    inst.avail_off = 16 * @as(usize, @intCast(inst.queue_size));
    var u_tmp = inst.avail_off + 4 + 2 * @as(usize, @intCast(inst.queue_size));
    u_tmp = (u_tmp + 3) & ~@as(usize, 3);
    inst.used_off = u_tmp;
    const used_end = inst.used_off + 4 + 8 * @as(usize, @intCast(inst.queue_size));
    if (used_end > inst.ring_page.len) {
        failDevice(inst, mmio_r8(inst.common_base, 0x14));
        return false;
    }
    inst.event_slot_off = (used_end + 7) & ~@as(usize, 7);
    const qs_us = @as(usize, @intCast(inst.queue_size));
    if (inst.event_slot_off + qs_us * @as(usize, @intCast(RECV_BYTES_PER_DESC)) > inst.ring_page.len) {
        failDevice(inst, mmio_r8(inst.common_base, 0x14));
        return false;
    }

    remapInstQueueDmaUncached(inst);
    fullMemoryFence();
    @memset(&inst.ring_page, 0);

    const page_phys: u64 = @intCast(vm.kernelVirtToPhys(@intFromPtr(&inst.ring_page)));
    const ev0_phys: u64 = page_phys + @as(u64, @intCast(inst.event_slot_off));

    var di: u16 = 0;
    while (di < inst.queue_size) : (di += 1) {
        const slot_phys = page_phys + @as(u64, @intCast(inst.event_slot_off + @as(usize, @intCast(di)) * @as(usize, @intCast(RECV_BYTES_PER_DESC))));
        descTable(inst)[di] = .{
            .addr = slot_phys,
            .len = RECV_BYTES_PER_DESC,
            .flags = VRING_DESC_F_WRITE,
            .next = 0,
        };
    }

    mmio_w32(inst.common_base, 0x20, @truncate(page_phys));
    mmio_w32(inst.common_base, 0x24, @truncate(page_phys >> 32));
    mmio_w32(inst.common_base, 0x28, @truncate(page_phys + inst.avail_off));
    mmio_w32(inst.common_base, 0x2c, @truncate((page_phys + inst.avail_off) >> 32));
    mmio_w32(inst.common_base, 0x30, @truncate(page_phys + inst.used_off));
    mmio_w32(inst.common_base, 0x34, @truncate((page_phys + inst.used_off) >> 32));

    inst.queue_notify_off = mmio_r16(inst.common_base, 0x1e);
    mmio_w16(inst.common_base, 0x1c, 1);

    // 须先填满 avail 再 DRIVER_OK：若先置 DRIVER_OK，QEMU 可能在 avail 尚未写入时读队列并认为空（H6：used 永 0）。
    inst.last_used_idx = 0;
    inst.local_avail_idx = 0;
    di = 0;
    while (di < inst.queue_size) : (di += 1) {
        availRingIndex(inst, di).* = di;
    }
    inst.local_avail_idx = inst.queue_size;
    readAvailIdxWrite(inst, inst.queue_size);
    fullMemoryFence();

    mmio_w8(inst.common_base, 0x14, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);
    fullMemoryFence();
    kickQueue0(inst);

    inst.active = true;
    // #region agent log
    if (@import("build_options").agent_ndjson) {
        const ag = @import("../../debug/agent_ndjson.zig");
        const st7 = mmio_r8(inst.common_base, 0x14);
        ag.emit("H7", "virtio_input_pci:attach", "ring_gpa_status", "pre", page_phys, ev0_phys, @intFromPtr(&inst.ring_page), @as(u64, @intCast(inst.event_slot_off)), st7, @as(i64, @intCast(inst.queue_size)));
    }
    // #endregion
    klog.info("VirtIO-Input PCI: queue_size=%u notify_off=%u (mouse/keyboard PCI)", .{
        inst.queue_size, inst.queue_notify_off,
    });
    return true;
}

pub fn init() void {
    if (!pcie.supports_pci_config) return;

    var locs: [MAX_INST + 4]pcie.PciLoc = undefined;
    // x86_64：默认 QEMU `pc` 在 bus0；若用户挂 pci-bridge 或换机型，VirtIO Input 可能落在 bus1–2。
    const max_bus: u8 = if (builtin.target.cpu.arch == .x86_64) 2 else 7;
    const n = pcie.collectVirtioInputDevices(locs[0..], max_bus);

    if (n == 0) {
        if (builtin.target.cpu.arch != .x86_64) {
            klog.warn("VirtIO-Input PCI: no 1af4:1052 on non-x86 — 指针依赖 VirtIO；QEMU 请加 virtio-mouse-pci（Makefile 与 docs/cn/AeroDesktopRuntime.md）", .{});
        } else {
            klog.info("VirtIO-Input PCI: no 1af4:1052 (optional: -device virtio-mouse-pci,virtio-keyboard-pci)", .{});
        }
        // #region agent log
        if (@import("build_options").agent_ndjson) {
            const ag = @import("../../debug/agent_ndjson.zig");
            ag.emit("H1", "virtio_input_pci:init", "no_pci_devices", "pre", 0, 0, 0, 0, 0, 0);
        }
        // #endregion
        return;
    }

    var slot: usize = 0;
    var i: usize = 0;
    while (i < n and slot < MAX_INST) : (i += 1) {
        const loc = locs[i];
        const cmd = pcie.readConfigDword(loc.bus, loc.dev, loc.func, 0x04);
        pcie.writeConfigDword(loc.bus, loc.dev, loc.func, 0x04, cmd | 0x7);

        if (virtioAttachModern(&instances[slot], loc)) {
            slot += 1;
        }
    }

    if (slot == 0) {
        klog.warn("VirtIO-Input PCI: attach failed for all devices", .{});
    }

    // #region agent log
    if (@import("build_options").agent_ndjson) {
        const ag = @import("../../debug/agent_ndjson.zig");
        ag.emit("H1", "virtio_input_pci:init", "attach_summary", "pre", @as(u64, @intCast(n)), @as(u64, @intCast(slot)), if (isActive()) @as(u64, 1) else 0, 0, 0, 0);
    }
    // #endregion
}

pub fn isActive() bool {
    for (&instances) |*inst| {
        if (inst.active) return true;
    }
    return false;
}

/// 显示分辨率或指针边界变化后调用：丢弃 ABS 基线，避免 tablet 与 `mouse` 坐标脱节。
pub fn resetPointerBaseline() void {
    for (&instances) |*inst| {
        inst.tab_have_x = false;
        inst.tab_have_y = false;
        inst.abs_frame_dirty = false;
        inst.acc_dx = 0;
        inst.acc_dy = 0;
        inst.acc_scroll = 0;
        inst.has_pointer_ev = false;
    }
}
