//! xHCI 1.x 最小主机驱动：PCI BAR、命令环/事件环、根口复位、枚举、控制传输、
//! Boot HID 鼠标中断 IN 轮询。
//!
//! QEMU 矩阵（建议）：`-device qemu-xhci` + `usb-tablet` / `usb-mouse`；
//! `-device usb-hub,bus=xhci.0` 下挂设备；EHCI 回退见 `ehci.zig`。
//! 真机需 MSI/线 IRQ；当前为 **事件环轮询**（`poll()`）。

const builtin = @import("builtin");
const std = @import("std");
const pcie = @import("../bus/pcie.zig");
const vm = @import("../../mm/vm.zig");
const klog = @import("../../rtl/klog.zig");
const dma = @import("dma.zig");
const usb_core = @import("usb_core.zig");
const hub_pkg = @import("hub.zig");
const hid = @import("hid.zig");

const CMD_RING_SZ: usize = 64;
const EVT_RING_SZ: usize = 128;
const EP0_RING_SZ: usize = 64;
const INTR_RING_SZ: usize = 8;

const Trb = extern struct {
    param_lo: u32,
    param_hi: u32,
    status: u32,
    control: u32,
};

const ErstEntry = extern struct {
    seg_base_lo: u32,
    seg_base_hi: u32,
    seg_size: u16,
    _rsvd: u16 = 0,
    _rsvd2: u32 = 0,
};

const TRB_NORMAL: u32 = 1;
const TRB_SETUP: u32 = 2;
const TRB_DATA: u32 = 3;
const TRB_STATUS: u32 = 4;
const TR_CMD_NOOP: u32 = 23;
const TR_CMD_ENABLE_SLOT: u32 = 9;
const TR_CMD_ADDRESS_DEV: u32 = 11;
const TR_CMD_CONFIGURE_EP: u32 = 12;
const TR_CMD_EVAL_CTX: u32 = 13;
const TR_EVT_TRANSFER: u32 = 32;
const TR_EVT_CMD_CMPL: u32 = 33;

const CC_SUCCESS: u8 = 1;

const PORT_CONNECT: u32 = 1 << 0;
const PORT_PE: u32 = 1 << 1;
const PORT_RESET: u32 = 1 << 4;

const TRB_CHAIN: u32 = 1 << 4;
const TRB_IOC: u32 = 1 << 5;
const TRB_DIR_IN: u32 = 1 << 16;

fn mfence() void {
    switch (builtin.target.cpu.arch) {
        .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        else => asm volatile ("" ::: .{ .memory = true }),
    }
}

fn r8(base: usize, off: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(base + off)).*;
}
fn r16(base: usize, off: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(base + off)).*;
}
fn r32(base: usize, off: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(base + off)).*;
}
fn w32(base: usize, off: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(base + off)).* = v;
}
fn w64(base: usize, off: usize, v: u64) void {
    const p = base + off;
    @as(*volatile u32, @ptrFromInt(p)).* = @truncate(v);
    @as(*volatile u32, @ptrFromInt(p + 4)).* = @truncate(v >> 32);
}

var g_active: bool = false;
var g_mmio: usize = 0;
var g_cap: usize = 0;
var g_op: usize = 0;
var g_rts: usize = 0;
var g_db: usize = 0;
var g_max_slots: u8 = 0;
var g_max_ports: u8 = 0;
var g_ctx_bytes: usize = 32;
var g_dw_per_ctx: usize = 8;

var g_cmd_ring: [CMD_RING_SZ]Trb align(64) = undefined;
var g_cmd_enq: usize = 0;
var g_cmd_cycle: bool = true;

var g_evt_ring: [EVT_RING_SZ]Trb align(64) = undefined;
var g_evt_deq: usize = 0;
var g_evt_cycle: bool = true;

var g_erst: [1]ErstEntry align(64) = undefined;
/// 每项 [lo,hi] 小端等价 u64，避免内核模型下对 `[256]u64` 整块 memset 触发编码器问题。
var g_dcbaa: [256][2]u32 align(64) = undefined;

fn setDcbaaEntry(idx: usize, phys: u64) void {
    g_dcbaa[idx][0] = @truncate(phys);
    g_dcbaa[idx][1] = @truncate(phys >> 32);
}
var g_scratch_ptrs: [32]u64 align(64) = undefined;
var g_scratch_pages: [32][4096]u8 align(4096) = undefined;

var g_dev_ctx: [16][2048]u8 align(4096) = undefined;
var g_input_ctx: [4096]u8 align(4096) = undefined;

var g_ep0_ring: [4][EP0_RING_SZ]Trb align(64) = undefined;
var g_ep0_enq: [4]u16 = .{0} ** 4;
var g_ep0_cyc: [4]bool = .{true} ** 4;

var g_intr_ring: [4][INTR_RING_SZ]Trb align(64) = undefined;
var g_intr_enq: [4]u16 = .{0} ** 4;
var g_intr_cyc: [4]bool = .{true} ** 4;
var g_intr_buf: [4][64]u8 align(64) = undefined;

var g_slot_port: [4]u8 = .{0} ** 4;
var g_slot_valid: [4]bool = .{false} ** 4;
var g_hid_ep_id: [4]u8 = .{0} ** 4;
var g_hid_mps: [4]u16 = .{0} ** 4;
var g_hid_ready: [4]bool = .{false} ** 4;
var g_hid_await: [4]bool = .{false} ** 4;

var g_last_cmd_cc: u8 = 0;
var g_last_cmd_slot: u8 = 0;

var g_xfer_done: bool = false;
var g_xfer_slot: u8 = 0;
var g_xfer_ep: u8 = 0;
var g_xfer_cc: u8 = 0;

fn trbTyp(ctrl: u32) u32 {
    return (ctrl >> 10) & 0x3f;
}
fn trbCycle(ctrl: u32) bool {
    return (ctrl & 1) != 0;
}
fn ctrlTrb(cycle: bool, typ: u32, extra: u32) u32 {
    var c: u32 = if (cycle) 1 else 0;
    c |= extra;
    c |= typ << 10;
    return c;
}

fn portscOff(port1: u8) usize {
    return 0x400 + (@as(usize, port1 - 1) * 0x10);
}

fn readPortSpeed(port1: u8) u8 {
    const v = r32(g_op, portscOff(port1));
    return @truncate((v >> 10) & 0xF);
}

fn waitHcrstDone() void {
    var i: u32 = 0;
    while (i < 1_000_000) : (i += 1) {
        if ((r32(g_op, 0x00) & (1 << 1)) == 0) return;
    }
}

fn waitHalted(want: bool) void {
    var i: u32 = 0;
    while (i < 1_000_000) : (i += 1) {
        const h = (r32(g_op, 0x04) & 1) != 0;
        if (h == want) return;
    }
}

fn setTrbParam(tr: *Trb, param: u64) void {
    tr.param_lo = @truncate(param);
    tr.param_hi = @truncate(param >> 32);
}

fn cmdPushEx(param: u64, status: u32, typ: u32, ctrl_extra: u32) void {
    const i = g_cmd_enq;
    const cyc = g_cmd_cycle;
    const tr = &g_cmd_ring[i];
    setTrbParam(tr, param);
    tr.status = status;
    tr.control = ctrlTrb(cyc, typ, ctrl_extra);
    g_cmd_enq = (i + 1) % CMD_RING_SZ;
    if (g_cmd_enq == 0) g_cmd_cycle = !g_cmd_cycle;
}

fn cmdPushSlot(param: u64, typ: u32, slot: u8) void {
    cmdPushEx(param, 0, typ, @as(u32, slot) << 24);
}

fn ringCmdDoorbell() void {
    mfence();
    w32(g_db, 0, 0);
}

fn ringEpDoorbell(slot: u8, ep_id: u8) void {
    const off = @as(usize, slot) * 4;
    mfence();
    w32(g_db, off, @as(u32, ep_id) << 8 | 1);
}

fn updateErdp() void {
    const phys = dma.virtToPhys(@intFromPtr(&g_evt_ring[g_evt_deq]));
    w64(g_rts, 0x18, phys | (1 << 3));
}

fn evtProcess(trb: Trb) void {
    const t = trbTyp(trb.control);
    if (t == TR_EVT_CMD_CMPL) {
        g_last_cmd_cc = @truncate((trb.status >> 24) & 0xff);
        g_last_cmd_slot = @truncate((trb.control >> 24) & 0xff);
    } else if (t == TR_EVT_TRANSFER) {
        g_xfer_slot = @truncate((trb.control >> 24) & 0xff);
        g_xfer_ep = @truncate((trb.control >> 16) & 0x1f);
        g_xfer_cc = @truncate((trb.status >> 24) & 0xff);
        g_xfer_done = true;
    }
}

fn drainEvents(max: usize) void {
    var n: usize = 0;
    while (n < max) : (n += 1) {
        const trb = g_evt_ring[g_evt_deq];
        if (trbCycle(trb.control) != g_evt_cycle) break;
        evtProcess(trb);
        g_evt_deq = (g_evt_deq + 1) % EVT_RING_SZ;
        if (g_evt_deq == 0) g_evt_cycle = !g_evt_cycle;
        updateErdp();
    }
}

fn waitCmdCompletion(iter: u32) bool {
    g_last_cmd_cc = 0;
    g_last_cmd_slot = 0;
    var i: u32 = 0;
    while (i < iter) : (i += 1) {
        drainEvents(48);
        if (g_last_cmd_cc != 0) return g_last_cmd_cc == CC_SUCCESS;
    }
    return false;
}

fn ep0Push(si: usize, param: u64, status_len: u32, typ: u32, extra: u32) void {
    const i = @as(usize, g_ep0_enq[si]);
    const cyc = g_ep0_cyc[si];
    const tr = &g_ep0_ring[si][i];
    setTrbParam(tr, param);
    tr.status = status_len;
    tr.control = ctrlTrb(cyc, typ, extra);
    g_ep0_enq[si] = @truncate((@as(u16, @intCast(i)) + 1) % EP0_RING_SZ);
    if (g_ep0_enq[si] == 0) g_ep0_cyc[si] = !g_ep0_cyc[si];
}

fn waitXferEvent(slot: u8, ep_id: u8, iter: u32) bool {
    g_xfer_done = false;
    var i: u32 = 0;
    while (i < iter) : (i += 1) {
        drainEvents(64);
        if (g_xfer_done and g_xfer_slot == slot and g_xfer_ep == ep_id and g_xfer_cc == CC_SUCCESS)
            return true;
    }
    return false;
}

fn controlTransfer(slot: u8, si: usize, setup: usb_core.SetupPacket, data_buf: ?[]u8, out_data: bool) bool {
    const dw0 = @as(u32, setup.bmRequestType) | (@as(u32, setup.bRequest) << 8) | (@as(u32, setup.wValue) << 16);
    const dw1 = @as(u32, setup.wIndex) | (@as(u32, setup.wLength) << 16);
    const setup_param = @as(u64, dw0) | (@as(u64, dw1) << 32);
    const trt: u32 = if (setup.wLength == 0) 0 else if (out_data) 1 else 2;

    if (setup.wLength > 0) {
        const setup_extra = trt << 16 | TRB_CHAIN;
        ep0Push(si, setup_param, 8, TRB_SETUP, setup_extra);
        const buf = data_buf orelse return false;
        const p = dma.virtToPhys(@intFromPtr(buf.ptr));
        const dir: u32 = if (!out_data) TRB_DIR_IN else 0;
        const data_extra = TRB_CHAIN | dir;
        ep0Push(si, p, setup.wLength, TRB_DATA, data_extra);
        const st_dir: u32 = if (out_data) TRB_DIR_IN else 0;
        ep0Push(si, 0, 0, TRB_STATUS, TRB_IOC | st_dir);
    } else {
        const setup_extra = trt << 16 | TRB_CHAIN;
        ep0Push(si, setup_param, 8, TRB_SETUP, setup_extra);
        ep0Push(si, 0, 0, TRB_STATUS, TRB_IOC);
    }

    ringEpDoorbell(slot, 1);
    return waitXferEvent(slot, 1, 800_000);
}

fn icDwordPtr() [*]volatile u32 {
    return @ptrCast(@alignCast(&g_input_ctx));
}

fn inputCtxClearAdd(add1: u32) void {
    @memset(&g_input_ctx, 0);
    icDwordPtr()[1] = add1;
}

fn slotCtxAtRoot(port1: u8, speed: u8, ctx_entries: u8) void {
    const s = icDwordPtr();
    s[8] = @as(u32, speed) << 26;
    s[9] = @as(u32, ctx_entries) | (@as(u32, port1) << 16);
}

fn ep0CtxInput(mps: u16) void {
    const s = icDwordPtr();
    const b = 8 + g_dw_per_ctx;
    s[b + 0] = 1;
    s[b + 1] = (3 << 1) | (4 << 3) | (@as(u32, mps) << 16);
}

fn epIntrCtxInput(ep_id: u8, mps: u16, interval: u8) void {
    const s = icDwordPtr();
    const b = 8 + @as(usize, ep_id) * g_dw_per_ctx;
    s[b + 0] = interval;
    s[b + 1] = (3 << 1) | (7 << 3) | (@as(u32, mps) << 16);
    s[b + 1] |= 1;
}

fn loadDevSlotEp0ToInput(si: usize) void {
    const n = 2 * g_ctx_bytes;
    @memcpy(g_input_ctx[32..][0..n], g_dev_ctx[si][0..n]);
}

fn addressDevice(slot: u8, port1: u8, speed: u8) bool {
    inputCtxClearAdd(0x03);
    slotCtxAtRoot(port1, speed, 1);
    ep0CtxInput(8);
    dma.prepareDmaSlice(&g_input_ctx);
    cmdPushSlot(dma.virtToPhys(@intFromPtr(&g_input_ctx)), TR_CMD_ADDRESS_DEV, slot);
    ringCmdDoorbell();
    return waitCmdCompletion(400_000);
}

fn evaluateEp0Mps(slot: u8, si: usize, mps: u16) bool {
    loadDevSlotEp0ToInput(si);
    @memset(g_input_ctx[0..32], 0);
    icDwordPtr()[1] = 1 << 1;
    const b = 8 + g_dw_per_ctx;
    const ic = icDwordPtr();
    ic[b + 0] = 1;
    ic[b + 1] = (3 << 1) | (4 << 3) | (@as(u32, mps) << 16);
    dma.prepareDmaSlice(&g_input_ctx);
    cmdPushSlot(dma.virtToPhys(@intFromPtr(&g_input_ctx)), TR_CMD_EVAL_CTX, slot);
    ringCmdDoorbell();
    return waitCmdCompletion(400_000);
}

fn enableSlot() ?u8 {
    cmdPushEx(0, 0, TR_CMD_ENABLE_SLOT, 0);
    ringCmdDoorbell();
    if (!waitCmdCompletion(400_000)) return null;
    if (g_last_cmd_slot == 0) return null;
    return g_last_cmd_slot;
}

fn resetPort(port1: u8) bool {
    const off = portscOff(port1);
    var v = r32(g_op, off);
    v |= PORT_RESET;
    w32(g_op, off, v);
    var i: u32 = 0;
    while (i < 800_000) : (i += 1) {
        drainEvents(4);
        const x = r32(g_op, off);
        if ((x & PORT_RESET) == 0 and (x & PORT_PE) != 0) return true;
    }
    return false;
}

fn hubEnumerate(slot: u8, si: usize, num_ports: u8) void {
    var p: u8 = 1;
    while (p <= num_ports) : (p += 1) {
        var st: [4]u8 align(64) = undefined;
        dma.prepareDmaSlice(&st);
        _ = controlTransfer(slot, si, hub_pkg.getPortStatusSetup(p), &st, false);
        const w = usb_core.readU16Le(&st, 0);
        if ((w & 1) == 0) continue;
        _ = controlTransfer(slot, si, hub_pkg.setPortFeatureSetup(p, hub_pkg.PORT_FEAT_RESET), null, false);
        var k: u32 = 0;
        while (k < 20_000) : (k += 1) drainEvents(8);
        klog.info("USB hub port %u: activity (hub slot=%u)", .{ p, slot });
    }
}

fn attachDeviceOnPort(port1: u8) void {
    if (!resetPort(port1)) {
        klog.warn("USB: port %u reset failed", .{port1});
        return;
    }
    const speed = readPortSpeed(port1);
    const sid = enableSlot() orelse {
        klog.warn("USB: enable slot failed", .{});
        return;
    };
    if (sid < 1 or sid > 4) {
        klog.warn("USB: slot id %u unsupported", .{sid});
        return;
    }
    const si = sid - 1;
    g_slot_port[si] = port1;
    g_slot_valid[si] = true;
    g_ep0_enq[si] = 0;
    g_ep0_cyc[si] = true;
    @memset(&g_dev_ctx[si], 0);
    dma.prepareDmaSlice(std.mem.sliceAsBytes(&g_ep0_ring[si]));
    dma.prepareDmaSlice(&g_dev_ctx[si]);
    setDcbaaEntry(sid, dma.virtToPhys(@intFromPtr(&g_dev_ctx[si])));

    if (!addressDevice(sid, port1, speed)) {
        klog.warn("USB: ADDRESS_DEVICE failed slot=%u cc=%u", .{ sid, g_last_cmd_cc });
        return;
    }

    var d8: [8]u8 align(64) = undefined;
    dma.prepareDmaSlice(&d8);
    const g8 = usb_core.SetupPacket{
        .bmRequestType = usb_core.REQ_TYPE_DEVICE_IN,
        .bRequest = usb_core.REQ_GET_DESCRIPTOR,
        .wValue = (@as(u16, usb_core.DESC_DEVICE) << 8),
        .wIndex = 0,
        .wLength = 8,
    };
    if (!controlTransfer(sid, si, g8, &d8, false)) {
        klog.warn("USB: GET_DESCRIPTOR(8) failed", .{});
        return;
    }
    const mps0 = d8[7];
    if (!evaluateEp0Mps(sid, si, mps0)) {
        klog.warn("USB: EVALUATE_CONTEXT failed", .{});
        return;
    }

    var ddev: [64]u8 align(64) = undefined;
    dma.prepareDmaSlice(&ddev);
    const gdev = usb_core.SetupPacket{
        .bmRequestType = usb_core.REQ_TYPE_DEVICE_IN,
        .bRequest = usb_core.REQ_GET_DESCRIPTOR,
        .wValue = (@as(u16, usb_core.DESC_DEVICE) << 8),
        .wIndex = 0,
        .wLength = 18,
    };
    if (!controlTransfer(sid, si, gdev, &ddev, false)) {
        klog.warn("USB: GET_DESCRIPTOR(dev) failed", .{});
        return;
    }

    var cfghead: [9]u8 align(64) = undefined;
    dma.prepareDmaSlice(&cfghead);
    const gcfg = usb_core.SetupPacket{
        .bmRequestType = usb_core.REQ_TYPE_DEVICE_IN,
        .bRequest = usb_core.REQ_GET_DESCRIPTOR,
        .wValue = (@as(u16, usb_core.DESC_CONFIG) << 8),
        .wIndex = 0,
        .wLength = 9,
    };
    if (!controlTransfer(sid, si, gcfg, &cfghead, false)) {
        klog.warn("USB: GET_DESCRIPTOR(cfg hdr) failed", .{});
        return;
    }
    const total_len = usb_core.readU16Le(&cfghead, 2);
    if (total_len == 0 or total_len > 512) {
        klog.warn("USB: bad wTotalLength %u", .{total_len});
        return;
    }
    var cfb: [512]u8 align(64) = undefined;
    dma.prepareDmaSlice(&cfb);
    const gcfull = usb_core.SetupPacket{
        .bmRequestType = usb_core.REQ_TYPE_DEVICE_IN,
        .bRequest = usb_core.REQ_GET_DESCRIPTOR,
        .wValue = (@as(u16, usb_core.DESC_CONFIG) << 8),
        .wIndex = 0,
        .wLength = total_len,
    };
    if (!controlTransfer(sid, si, gcfull, cfb[0..total_len], false)) {
        klog.warn("USB: GET_DESCRIPTOR(cfg) failed", .{});
        return;
    }

    if (usb_core.findHubInterface(cfb[0..total_len])) |_| {
        var hd: [16]u8 align(64) = undefined;
        dma.prepareDmaSlice(&hd);
        const hs = hub_pkg.hubGetDescriptorSetup(9);
        if (controlTransfer(sid, si, hs, &hd, false)) {
            const nports = hd[2];
            klog.info("USB: hub nPorts=%u slot=%u", .{ nports, sid });
            hubEnumerate(sid, si, nports);
        }
        return;
    }

    const hid_path = usb_core.findBootHidInterruptIn(cfb[0..total_len]) orelse {
        klog.info("USB: port %u: non-HID-boot device slot=%u", .{ port1, sid });
        return;
    };

    const ep: *align(1) const usb_core.EndpointDescriptor = @ptrCast(cfb[hid_path.ep_off..][0..@sizeOf(usb_core.EndpointDescriptor)]);
    const ep_addr = ep.bEndpointAddress;
    const ep_num = ep_addr & 0xF;
    const ep_in = (ep_addr & 0x80) != 0;
    const ep_id: u8 = if (ep_num == 0) 1 else @truncate(ep_num * 2 + @as(u8, if (ep_in) 1 else 0));
    const mps = ep.wMaxPacketSize & 0x7FF;
    const iv = if (ep.bInterval < 1) @as(u8, 1) else ep.bInterval;

    const set_cfg = usb_core.SetupPacket{
        .bmRequestType = usb_core.REQ_TYPE_DEVICE_OUT,
        .bRequest = usb_core.REQ_SET_CONFIGURATION,
        .wValue = 1,
        .wIndex = 0,
        .wLength = 0,
    };
    if (!controlTransfer(sid, si, set_cfg, null, true)) {
        klog.warn("USB: SET_CONFIGURATION failed", .{});
        return;
    }

    // TT：FS/LS 经 HS Hub 时须在 Slot Context 填 TT Hub Slot / TT Port（当前仅根口直挂）。
    const iface_num = cfb[hid_path.iface_off + 2];
    const add_ep: u32 = @as(u32, 1) << @intCast(@min(ep_id, 31));
    inputCtxClearAdd((1 << 0) | (1 << 1) | add_ep);
    slotCtxAtRoot(g_slot_port[si], readPortSpeed(g_slot_port[si]), ep_id);
    ep0CtxInput(@max(mps0, 64));
    epIntrCtxInput(ep_id, mps, iv);
    const ic = icDwordPtr();
    ic[7] = 1;
    dma.prepareDmaSlice(&g_input_ctx);
    cmdPushSlot(dma.virtToPhys(@intFromPtr(&g_input_ctx)), TR_CMD_CONFIGURE_EP, sid);
    ringCmdDoorbell();
    if (!waitCmdCompletion(400_000)) {
        klog.warn("USB: CONFIGURE_EP failed cc=%u", .{g_last_cmd_cc});
        return;
    }

    const set_boot = usb_core.SetupPacket{
        .bmRequestType = 0x21,
        .bRequest = usb_core.HID_REQ_SET_PROTOCOL,
        .wValue = usb_core.HID_PROTOCOL_BOOT,
        .wIndex = iface_num,
        .wLength = 0,
    };
    _ = controlTransfer(sid, si, set_boot, null, true);

    g_hid_ep_id[si] = ep_id;
    g_hid_mps[si] = mps;
    g_hid_ready[si] = true;
    g_hid_await[si] = false;
    g_intr_enq[si] = 0;
    g_intr_cyc[si] = true;
    dma.prepareDmaSlice(&g_intr_buf[si]);
    dma.prepareDmaSlice(std.mem.sliceAsBytes(&g_intr_ring[si]));

    klog.info("USB: HID boot mouse slot=%u ep=%u mps=%u", .{ sid, ep_id, mps });
}

fn hidQueueIn(si: usize, slot: u8) void {
    if (g_hid_await[si]) return;
    const i = @as(usize, g_intr_enq[si]);
    const cyc = g_intr_cyc[si];
    const p = dma.virtToPhys(@intFromPtr(&g_intr_buf[si]));
    const mps = g_hid_mps[si];
    const itr = &g_intr_ring[si][i];
    setTrbParam(itr, p);
    itr.status = mps | TRB_IOC;
    itr.control = ctrlTrb(cyc, TRB_NORMAL, 0);
    g_intr_enq[si] = @truncate((@as(u16, @intCast(i)) + 1) % INTR_RING_SZ);
    if (g_intr_enq[si] == 0) g_intr_cyc[si] = !g_intr_cyc[si];
    g_hid_await[si] = true;
    ringEpDoorbell(slot, g_hid_ep_id[si]);
}

fn pollHidOne(si: usize, slot: u8) void {
    if (!g_hid_ready[si]) return;
    if (!g_hid_await[si]) hidQueueIn(si, slot);
    g_xfer_done = false;
    drainEvents(96);
    if (g_xfer_done and g_xfer_slot == slot and g_xfer_ep == g_hid_ep_id[si] and g_xfer_cc == CC_SUCCESS) {
        g_hid_await[si] = false;
        hid.deliverBootMouseReport(g_intr_buf[si][0..@min(g_hid_mps[si], 64)]);
    }
}

pub fn poll() void {
    if (!g_active) return;
    drainEvents(16);
    var si: usize = 0;
    while (si < 4) : (si += 1) {
        if (!g_slot_valid[si]) continue;
        pollHidOne(si, @truncate(si + 1));
    }
}

pub fn isActive() bool {
    return g_active;
}

pub fn initFromPci(info: pcie.UsbHostPciInfo) bool {
    if (info.kind != .xhci) return false;
    const bar = pcie.firstMmioBarUsb(&info) orelse return false;
    if (!vm.mapDeviceMmioIdentity(bar.base, bar.size)) {
        klog.warn("USB xHCI: MMIO map failed", .{});
        return false;
    }
    g_mmio = @intCast(bar.base);
    g_cap = g_mmio;
    const caplen: usize = r8(g_cap, 0);
    g_op = g_cap + caplen;
    const hciversion = r16(g_cap, 2);
    const hcs1 = r32(g_cap, 0x04);
    const hcs2 = r32(g_cap, 0x08);
    const hcc1 = r32(g_cap, 0x10);
    g_max_slots = @truncate(hcs1 & 0xff);
    g_max_ports = @truncate((hcs1 >> 24) & 0xff);
    const dboff = r32(g_cap, 0x14);
    const rtsoff = r32(g_cap, 0x18);
    g_db = g_cap + (dboff & ~@as(u32, 3));
    g_rts = g_cap + (rtsoff & ~@as(u32, 0x1f));

    g_ctx_bytes = if ((hcc1 & (1 << 2)) != 0) @as(usize, 64) else 32;
    g_dw_per_ctx = g_ctx_bytes / 4;

    klog.info("USB xHCI: HCI ver=0x%x slots=%u ports=%u ctxB=%u MMIO=0x%x", .{
        hciversion, g_max_slots, g_max_ports, g_ctx_bytes, g_mmio,
    });

    const xecp = (hcc1 >> 16) & 0xffff;
    var xcap: usize = if (xecp != 0) g_cap + (@as(usize, xecp) << 2) else 0;
    var guard: u32 = 0;
    while (xcap != 0 and guard < 48) : (guard += 1) {
        const capd = r32(xcap, 0);
        const next = (capd >> 20) & 0xfff;
        if (klog.DEBUG_MODE) klog.debug("USB xHCI xcap 0x%x", .{capd & 0xffff});
        if (next == 0) break;
        xcap +%= @as(usize, next) << 2;
    }

    @memset(@as([*]u8, @ptrCast(@alignCast(&g_dcbaa)))[0 .. 256 * 2 * @sizeOf(u32)], 0);
    const nscratch = (hcs2 >> 21) & 0x3f;
    if (nscratch > 0) {
        const n: usize = @min(nscratch, g_scratch_pages.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dma.prepareDmaSlice(&g_scratch_pages[i]);
            g_scratch_ptrs[i] = dma.virtToPhys(@intFromPtr(&g_scratch_pages[i]));
        }
        const sp: [*]u8 = @ptrCast(&g_scratch_ptrs);
        dma.prepareDmaSlice(sp[0 .. n * @sizeOf(u64)]);
        setDcbaaEntry(0, dma.virtToPhys(@intFromPtr(&g_scratch_ptrs)));
    }

    dma.prepareDmaSlice(std.mem.sliceAsBytes(&g_dev_ctx));
    dma.prepareDmaSlice(&g_input_ctx);
    dma.prepareDmaSlice(std.mem.sliceAsBytes(&g_cmd_ring));
    dma.prepareDmaSlice(std.mem.sliceAsBytes(&g_evt_ring));
    dma.prepareDmaSlice(std.mem.sliceAsBytes(&g_erst));

    w32(g_op, 0x00, 0);
    waitHalted(true);
    w32(g_op, 0x00, 1 << 1);
    waitHcrstDone();
    waitHalted(true);

    const max_slots_en = @min(g_max_slots, 255);
    w32(g_op, 0x38, max_slots_en);

    const dcbaap = dma.virtToPhys(@intFromPtr(&g_dcbaa));
    w64(g_op, 0x30, dcbaap);

    g_cmd_enq = 0;
    g_cmd_cycle = true;
    const crcr_phys = dma.virtToPhys(@intFromPtr(&g_cmd_ring));
    w64(g_op, 0x18, crcr_phys | 1);

    const eb = dma.virtToPhys(@intFromPtr(&g_evt_ring));
    g_erst[0].seg_base_lo = @truncate(eb);
    g_erst[0].seg_base_hi = @truncate(eb >> 32);
    g_erst[0].seg_size = EVT_RING_SZ;
    w32(g_rts, 0x08, 1);
    w64(g_rts, 0x10, dma.virtToPhys(@intFromPtr(&g_erst)));
    g_evt_deq = 0;
    g_evt_cycle = true;
    w64(g_rts, 0x18, dma.virtToPhys(@intFromPtr(&g_evt_ring)) | (1 << 3));
    w32(g_rts, 0x00, 3);

    w32(g_op, 0x00, 1);
    waitHalted(false);

    cmdPushEx(0, 0, TR_CMD_NOOP, 0);
    ringCmdDoorbell();
    if (!waitCmdCompletion(200_000)) {
        klog.warn("USB xHCI: NOOP failed cc=%u", .{g_last_cmd_cc});
    } else {
        klog.info("USB xHCI: command ring OK (NOOP)", .{});
    }

    var p: u8 = 1;
    while (p <= g_max_ports and p <= 16) : (p += 1) {
        if ((r32(g_op, portscOff(p)) & PORT_CONNECT) != 0) {
            klog.info("USB: root port %u connected", .{p});
            attachDeviceOnPort(p);
        }
    }

    g_active = true;
    return true;
}
