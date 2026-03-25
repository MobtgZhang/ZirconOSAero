//! Intel 集成显卡驱动（多代子集）：PCI 枚举、MMIO 映射、固件 GOP handoff 与桌面路径优先绑定。
//! 完整 KMS / ring 提交见 `intel/gen*_display.zig` 与 `intel/render_rings_stub.zig`。

const builtin = @import("builtin");
const build_options = @import("build_options");
const klog = @import("../../rtl/klog.zig");
const vm = @import("../../mm/vm.zig");
const pcie = @import("../bus/pcie.zig");

const types = @import("intel/types.zig");
const gen_detect = @import("intel/gen_detect.zig");
const gtt = @import("intel/gtt.zig");
const display_engine = @import("intel/display_engine.zig");
const hdmi_intel = @import("intel/hdmi_intel.zig");
const rings = @import("intel/render_rings_stub.zig");

/// 与 multiboot / UEFI handoff 对齐的帧缓冲参数
pub const DesktopFb = struct {
    addr: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u8,
    pixel_bgr: bool,
};

const max_pci_devices: usize = 4;
const max_scan_bus: u8 = 7;

var probe_ok: bool = false;
var probe_ran: bool = false;
var mmio_mapped: bool = false;
var primary: ?pcie.IntelGfxPciInfo = null;
var mmio_phys: u64 = 0;
var mmio_size: u64 = 0;
var mmio_virt: usize = 0;
var generation: types.IntelGpuGeneration = .unknown;
var display_result: types.DisplayInitResult = .failed;
var stolen: gtt.StolenInfo = .{};

pub fn isActive() bool {
    if (!build_options.intel_igpu) return false;
    return probe_ok;
}

/// 已启用延迟探测且尚未执行 PCI/BAR 扫描（首次 `resolveDesktopFramebuffer` 时执行）。
pub fn isDeferredProbePending() bool {
    if (!build_options.intel_igpu) return false;
    if (!build_options.intel_igpu_defer_probe) return false;
    return !probe_ran;
}

pub fn gpuGeneration() types.IntelGpuGeneration {
    return generation;
}

pub fn primaryDeviceId() ?u16 {
    if (primary) |p| return p.device_id;
    return null;
}

fn runPciProbeOnce() void {
    if (probe_ran) return;
    probe_ran = true;

    if (builtin.target.cpu.arch != .x86_64) return;
    if (!pcie.supports_pci_config) return;

    var buf: [max_pci_devices]pcie.IntelGfxPciInfo = undefined;
    const n = pcie.collectIntelDisplayDevices(buf[0..], max_scan_bus);
    if (n == 0) {
        if (klog.DEBUG_MODE) klog.info("Intel iGPU: no display-class 8086 device in bus 0..%u", .{max_scan_bus});
        return;
    }

    primary = buf[0];
    probe_ok = true;
    const dev = primary.?;

    generation = gen_detect.generationFromDeviceId(dev.device_id);
    stolen = gtt.probeStolenHeuristic(dev.loc);

    const mmio = pcie.firstMmioBar(&dev) orelse {
        klog.warn("Intel iGPU: no MMIO BAR (DID=0x%x)", .{dev.device_id});
        probe_ok = false;
        primary = null;
        return;
    };

    mmio_phys = mmio.base;
    mmio_size = mmio.size;
    if (mmio_size == 0 or mmio_phys == 0) {
        klog.warn("Intel iGPU: invalid MMIO BAR", .{});
        probe_ok = false;
        primary = null;
        return;
    }

    mmio_virt = @intCast(mmio_phys);
    mmio_mapped = vm.mapDeviceMmioIdentity(mmio_phys, mmio_size);
    if (!mmio_mapped) {
        klog.warn("Intel iGPU: mapDeviceMmioIdentity failed (phys=0x%x size=0x%x)", .{ mmio_phys, mmio_size });
    }

    display_result = display_engine.initForGeneration(generation, mmio_virt, build_options.intel_kms_experimental);

    klog.info("Intel iGPU: DID=0x%x rev=0x%x gen=%u bus=%u dev=%u fn=%u MMIO=0x%x size=0x%x stolen=%s", .{
        dev.device_id,
        dev.revision_id,
        @intFromEnum(generation),
        dev.loc.bus,
        dev.loc.dev,
        dev.loc.func,
        mmio_phys,
        mmio_size,
        if (stolen.valid) "yes" else "no",
    });
    klog.info("Intel iGPU: display_init=%u (handoff path when GOP present)", .{@intFromEnum(display_result)});
}

/// 延迟探测时由 `resolveDesktopFramebuffer` 在 GOP 参数就绪后调用。
pub fn ensureDeferredProbeCompleted() void {
    if (!build_options.intel_igpu) return;
    if (!build_options.intel_igpu_defer_probe) return;
    runPciProbeOnce();
}

/// 在引导帧缓冲上应用 Intel 路径：当前与 GOP 参数一致；未来可替换为自设 mode 的地址。
pub fn resolveDesktopFramebuffer(boot: DesktopFb) DesktopFb {
    rings.submitNoopStub();
    ensureDeferredProbeCompleted();
    if (!build_options.intel_igpu or !probe_ok) return boot;
    hdmi_intel.syncConnectorFromIntel(primary.?.device_id, generation);
    _ = gtt.installFramebufferGttStub(mmio_phys, @truncate(boot.addr), @as(usize, boot.pitch) * @as(usize, boot.height));
    return boot;
}

pub fn shutdown() void {
    probe_ok = false;
    probe_ran = false;
    primary = null;
    mmio_mapped = false;
    mmio_phys = 0;
    mmio_size = 0;
    mmio_virt = 0;
}

pub fn init() void {
    if (!build_options.intel_igpu) return;
    if (builtin.target.cpu.arch != .x86_64) return;
    if (!pcie.supports_pci_config) return;

    if (build_options.intel_igpu_defer_probe) {
        klog.info("Intel iGPU: PCI/BAR probe deferred until framebuffer resolve (intel_igpu_defer_probe)", .{});
        return;
    }
    runPciProbeOnce();
}
