//! VirtIO Input PCI（QEMU `-device virtio-mouse-pci` / `virtio-keyboard-pci`）
//! 现代 VirtIO 1.0 传输 + 事件队列轮询；支持最多 2 个 PCI 实例（键鼠各一）。
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
const REL_X: u16 = 0x0000;
const REL_Y: u16 = 0x0001;
const REL_WHEEL: u16 = 0x0008;
const BTN_LEFT: u16 = 0x0110;
const BTN_RIGHT: u16 = 0x0111;
const BTN_MIDDLE: u16 = 0x0112;

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

const MAX_INST: usize = 2;

const VirtioInputInst = struct {
    active: bool = false,
    common_base: usize = 0,
    notify_base: usize = 0,
    notify_mult: u32 = 0,
    isr_base: usize = 0,
    queue_notify_off: u16 = 0,
    queue_size: u16 = 0,
    ring_page: [4096]u8 align(4096) = undefined,
    event_pkt: [8]u8 align(8) = undefined,
    desc_off: usize = 0,
    avail_off: usize = 0,
    used_off: usize = 0,
    last_used_idx: u16 = 0,
    local_avail_idx: u16 = 0,
    hid_buttons: u8 = 0,
    acc_dx: i32 = 0,
    acc_dy: i32 = 0,
    acc_scroll: i32 = 0,
};

var instances: [MAX_INST]VirtioInputInst = .{ .{}, .{} };

fn fullMemoryFence() void {
    switch (builtin.target.cpu.arch) {
        .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
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

fn pciReadLe32(loc: pcie.PciLoc, off: u8) u32 {
    var v: u32 = 0;
    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        const sh: u5 = @intCast(i * 8);
        v |= @as(u32, pcie.readConfigByte(loc.bus, loc.dev, loc.func, off + i)) << sh;
    }
    return v;
}

fn barPhys32(loc: pcie.PciLoc, idx: u8) ?u64 {
    const raw = pcie.readConfigDword(loc.bus, loc.dev, loc.func, 0x10 + idx * 4);
    if (raw == 0xFFFFFFFF) return null;
    if ((raw & 1) != 0) return null;
    return raw & 0xFFFF_FFF0;
}

fn mapBarIfNeeded(phys: u64) bool {
    if (phys == 0) return false;
    return vm.mapDeviceMmioIdentity(phys, 0x4000);
}

fn readUsedIdx(inst: *VirtioInputInst) u16 {
    const p = @intFromPtr(&inst.ring_page) + inst.used_off;
    return @as(*volatile u16, @ptrFromInt(p + 2)).*;
}

fn readAvailIdxWrite(inst: *VirtioInputInst, val: u16) void {
    const p = @intFromPtr(&inst.ring_page) + inst.avail_off;
    @as(*volatile u16, @ptrFromInt(p + 2)).* = val;
}

fn availRingIndex(inst: *VirtioInputInst, i: u16) *volatile u16 {
    const p = @intFromPtr(&inst.ring_page) + inst.avail_off + 4 + @as(usize, @intCast(i)) * 2;
    return @as(*volatile u16, @ptrFromInt(p));
}

fn usedRingElem(inst: *VirtioInputInst, i: u16) struct { id: u32, len: u32 } {
    const qs = inst.queue_size;
    const p = @intFromPtr(&inst.ring_page) + inst.used_off + 4 + @as(usize, @intCast(@as(u32, i) % @as(u32, qs))) * 8;
    const id = @as(*volatile u32, @ptrFromInt(p)).*;
    const ln = @as(*volatile u32, @ptrFromInt(p + 4)).*;
    return .{ .id = id, .len = ln };
}

fn descTable(inst: *VirtioInputInst) [*]VirtqDesc {
    return @as([*]VirtqDesc, @ptrFromInt(@intFromPtr(&inst.ring_page) + inst.desc_off));
}

fn kickQueue0(inst: *VirtioInputInst) void {
    if (inst.notify_base == 0 or inst.notify_mult == 0) return;
    const port = inst.notify_base + @as(usize, inst.notify_mult) * @as(usize, inst.queue_notify_off);
    @as(*volatile u16, @ptrFromInt(port)).* = 0;
}

fn syncDeliver(inst: *VirtioInputInst) void {
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
}

fn parseLinuxInput(inst: *VirtioInputInst, le_pkt: *const [8]u8) void {
    const typ = @as(u16, @intCast(le_pkt[0])) | (@as(u16, @intCast(le_pkt[1])) << 8);
    const code = @as(u16, @intCast(le_pkt[2])) | (@as(u16, @intCast(le_pkt[3])) << 8);
    const val: i32 = @as(i32, @intCast(@as(u32, @intCast(le_pkt[4])) |
        (@as(u32, @intCast(le_pkt[5])) << 8) |
        (@as(u32, @intCast(le_pkt[6])) << 16) |
        (@as(u32, @intCast(le_pkt[7])) << 24)));

    switch (typ) {
        EV_REL => {
            if (code == REL_X) inst.acc_dx += val;
            if (code == REL_Y) inst.acc_dy += val;
            if (code == REL_WHEEL) inst.acc_scroll += val;
        },
        EV_KEY => {
            if (code == BTN_LEFT) {
                if (val != 0) inst.hid_buttons |= 1 else inst.hid_buttons &= ~@as(u8, 1);
            } else if (code == BTN_RIGHT) {
                if (val != 0) inst.hid_buttons |= 2 else inst.hid_buttons &= ~@as(u8, 2);
            } else if (code == BTN_MIDDLE) {
                if (val != 0) inst.hid_buttons |= 4 else inst.hid_buttons &= ~@as(u8, 4);
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

fn submitRecvBuffer(inst: *VirtioInputInst) void {
    const qs = inst.queue_size;
    if (qs == 0) return;
    const i = inst.local_avail_idx % qs;
    availRingIndex(inst, i).* = 0;
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

fn pollOne(inst: *VirtioInputInst) void {
    if (!inst.active) return;

    if (inst.isr_base != 0) {
        _ = mmio_r8(inst.isr_base, 0);
    }

    const used_idx = readUsedIdx(inst);
    while (inst.last_used_idx != used_idx) {
        const elem = usedRingElem(inst, inst.last_used_idx);
        _ = elem.len;
        _ = elem.id;
        if (elem.len >= 8) {
            parseLinuxInput(inst, @ptrCast(&inst.event_pkt));
        }
        inst.last_used_idx +%= 1;
        submitRecvBuffer(inst);
    }
}

pub fn poll() void {
    if (!pcie.supports_pci_config) return;
    for (&instances) |*inst| {
        pollOne(inst);
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

    var cap_ptr = pcie.readConfigByte(loc.bus, loc.dev, loc.func, 0x34);
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
    if (notify_mult_local == 0) notify_mult_local = 4;

    const b_phys_c = barPhys32(loc, common_bar) orelse return false;
    const b_phys_n = barPhys32(loc, notify_bar) orelse return false;
    if (!mapBarIfNeeded(b_phys_c)) return false;
    if (b_phys_n != b_phys_c) {
        if (!mapBarIfNeeded(b_phys_n)) return false;
    }

    inst.common_base = @intCast(b_phys_c + common_off);
    inst.notify_base = @intCast(b_phys_n + notify_off);
    inst.notify_mult = notify_mult_local;

    if (isr_bar < 6) {
        if (barPhys32(loc, isr_bar)) |bp| {
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
    const qs = mmio_r16(inst.common_base, 0x18);
    if (qs < 2 or qs > 256) {
        failDevice(inst, mmio_r8(inst.common_base, 0x14));
        return false;
    }
    inst.queue_size = @min(qs, 16);

    inst.desc_off = 0;
    inst.avail_off = 16 * @as(usize, @intCast(inst.queue_size));
    var u_tmp = inst.avail_off + 4 + 2 * @as(usize, @intCast(inst.queue_size));
    u_tmp = (u_tmp + 3) & ~@as(usize, 3);
    inst.used_off = u_tmp;
    if (inst.used_off + 4 + 8 * @as(usize, @intCast(inst.queue_size)) > inst.ring_page.len) {
        failDevice(inst, mmio_r8(inst.common_base, 0x14));
        return false;
    }

    @memset(&inst.ring_page, 0);

    const page_phys = @intFromPtr(&inst.ring_page);
    const ev_phys = @intFromPtr(&inst.event_pkt);

    descTable(inst)[0] = .{
        .addr = ev_phys,
        .len = 8,
        .flags = VRING_DESC_F_WRITE,
        .next = 0,
    };

    mmio_w32(inst.common_base, 0x20, @truncate(page_phys));
    mmio_w32(inst.common_base, 0x24, @truncate(page_phys >> 32));
    mmio_w32(inst.common_base, 0x28, @truncate(page_phys + inst.avail_off));
    mmio_w32(inst.common_base, 0x2c, @truncate((page_phys + inst.avail_off) >> 32));
    mmio_w32(inst.common_base, 0x30, @truncate(page_phys + inst.used_off));
    mmio_w32(inst.common_base, 0x34, @truncate((page_phys + inst.used_off) >> 32));

    inst.queue_notify_off = mmio_r16(inst.common_base, 0x1e);
    mmio_w16(inst.common_base, 0x1c, 1);

    inst.last_used_idx = 0;
    inst.local_avail_idx = 0;
    readAvailIdxWrite(inst, 0);
    availRingIndex(inst, 0).* = 0;
    inst.local_avail_idx = 1;
    readAvailIdxWrite(inst, 1);
    fullMemoryFence();
    kickQueue0(inst);

    mmio_w8(inst.common_base, 0x14, STATUS_ACK | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);
    inst.active = true;
    klog.info("VirtIO-Input PCI: queue_size=%u notify_off=%u (mouse/keyboard PCI)", .{
        inst.queue_size, inst.queue_notify_off,
    });
    return true;
}

pub fn init() void {
    if (!pcie.supports_pci_config) return;

    var locs: [MAX_INST + 4]pcie.PciLoc = undefined;
    const n = pcie.collectVirtioInputDevicesPci0(locs[0..]);

    if (n == 0) {
        klog.info("VirtIO-Input PCI: no 1af4:1052 (optional: -device virtio-mouse-pci,virtio-keyboard-pci)", .{});
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
}

pub fn isActive() bool {
    for (&instances) |*inst| {
        if (inst.active) return true;
    }
    return false;
}
