//! 龙芯 PCI 集成显卡（0014:03xx）：LoongArch 上枚举、MMIO 映射；帧缓冲仍走 UEFI GOP / ramfb handoff。
//! 阶段二 KMS 前 `resolveDesktopFramebuffer` 透传引导参数。

const builtin = @import("builtin");
const build_options = @import("build_options");
const klog = @import("../../rtl/klog.zig");
const vm = @import("../../mm/vm.zig");
const pcie = @import("../bus/pcie.zig");

const dids = @import("vendor/loongson/dids.zig");
const types = @import("vendor/loongson/types.zig");
const gen_detect = @import("vendor/loongson/gen_detect.zig");
const display_stub = @import("vendor/loongson/display_stub.zig");

pub const DesktopFb = @import("intel_igpu.zig").DesktopFb;

const max_pci_devices: usize = 4;
const max_scan_bus: u8 = 7;

var probe_ok: bool = false;
var probe_ran: bool = false;
var mmio_mapped: bool = false;
var primary: ?pcie.DisplayGfxPciInfo = null;
var mmio_phys: u64 = 0;
var mmio_size: u64 = 0;
var mmio_virt: usize = 0;
var generation: types.LoongsonGpuGeneration = .unknown;
var display_result: types.DisplayInitResult = .failed;

pub fn isActive() bool {
    if (!build_options.loongson_igpu) return false;
    return probe_ok;
}

pub fn isDeferredProbePending() bool {
    if (!build_options.loongson_igpu) return false;
    if (!build_options.loongson_igpu_defer_probe) return false;
    return !probe_ran;
}

pub fn gpuGeneration() types.LoongsonGpuGeneration {
    return generation;
}

pub fn primaryDeviceId() ?u16 {
    if (primary) |p| return p.device_id;
    return null;
}

fn pickSupportedDevice(buf: []pcie.DisplayGfxPciInfo, n: usize) ?pcie.DisplayGfxPciInfo {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (dids.isSupportedDisplayDid(buf[i].device_id)) return buf[i];
    }
    return null;
}

fn runPciProbeOnce() void {
    if (probe_ran) return;
    probe_ran = true;

    if (builtin.target.cpu.arch != .loongarch64) return;
    if (!build_options.loongson_igpu) return;
    if (!pcie.supports_pci_config) return;

    var buf: [max_pci_devices]pcie.DisplayGfxPciInfo = undefined;
    const n = pcie.collectLoongsonDisplayDevices(buf[0..], max_scan_bus);
    const dev = pickSupportedDevice(buf[0..], n) orelse {
        if (klog.DEBUG_MODE) klog.info("Loongson iGPU: no supported 0014 display DID in bus 0..%u", .{max_scan_bus});
        return;
    };

    primary = dev;
    probe_ok = true;

    generation = gen_detect.generationFromDeviceId(dev.device_id);

    const mmio = pcie.firstMmioBar(&dev) orelse {
        klog.warn("Loongson iGPU: no MMIO BAR (DID=0x%x)", .{dev.device_id});
        probe_ok = false;
        primary = null;
        return;
    };

    mmio_phys = mmio.base;
    mmio_size = mmio.size;
    if (mmio_size == 0 or mmio_phys == 0) {
        klog.warn("Loongson iGPU: invalid MMIO BAR", .{});
        probe_ok = false;
        primary = null;
        return;
    }

    mmio_virt = @intCast(mmio_phys);
    mmio_mapped = vm.mapDeviceMmioIdentity(mmio_phys, mmio_size);
    if (!mmio_mapped) {
        klog.warn("Loongson iGPU: mapDeviceMmioIdentity failed (phys=0x%x size=0x%x)", .{ mmio_phys, mmio_size });
    }

    display_result = display_stub.initForGeneration(generation, mmio_virt, build_options.loongson_kms_experimental);

    klog.info("Loongson iGPU: DID=0x%x rev=0x%x gen=%u bus=%u dev=%u fn=%u MMIO=0x%x size=0x%x", .{
        dev.device_id,
        dev.revision_id,
        @intFromEnum(generation),
        dev.loc.bus,
        dev.loc.dev,
        dev.loc.func,
        mmio_phys,
        mmio_size,
    });
    klog.info("Loongson iGPU: display_init=%u (handoff path when GOP/ramfb present)", .{@intFromEnum(display_result)});
}

pub fn ensureDeferredProbeCompleted() void {
    if (!build_options.loongson_igpu) return;
    if (!build_options.loongson_igpu_defer_probe) return;
    runPciProbeOnce();
}

pub fn resolveDesktopFramebuffer(boot: DesktopFb) DesktopFb {
    ensureDeferredProbeCompleted();
    if (!build_options.loongson_igpu or !probe_ok) return boot;
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
    generation = .unknown;
    display_result = .failed;
}

pub fn init() void {
    if (!build_options.loongson_igpu) return;
    if (builtin.target.cpu.arch != .loongarch64) return;
    if (!pcie.supports_pci_config) return;

    if (build_options.loongson_igpu_defer_probe) {
        klog.info("Loongson iGPU: PCI/BAR probe deferred until framebuffer resolve (loongson_igpu_defer_probe)", .{});
        return;
    }
    runPciProbeOnce();
}
