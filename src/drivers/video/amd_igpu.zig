//! AMD/ATI 集成显卡：PCI 枚举、MMIO 映射、固件 GOP handoff（与 `intel_igpu.zig` 对称）。
//! R7 及以下 APU 的 DID→族见 `amd/dids.zig`、`amd/family_detect.zig`；完整 KMS 为后续里程碑。

const builtin = @import("builtin");
const build_options = @import("build_options");
const klog = @import("../../rtl/klog.zig");
const vm = @import("../../mm/vm.zig");
const pcie = @import("../bus/pcie.zig");

const amd_types = @import("amd/types.zig");
const family_detect = @import("amd/family_detect.zig");
const display_handoff = @import("amd/display_handoff.zig");
const gmc_stub = @import("amd/gmc_stub.zig");

/// 与 multiboot / UEFI handoff 及 Intel 路径共用布局
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
var family: amd_types.AmdGpuFamily = .unknown;
var display_result: amd_types.DisplayInitResult = .failed;

pub fn isActive() bool {
    if (!build_options.amd_igpu) return false;
    return probe_ok;
}

pub fn isDeferredProbePending() bool {
    if (!build_options.amd_igpu) return false;
    if (!build_options.amd_igpu_defer_probe) return false;
    return !probe_ran;
}

pub fn gpuFamily() amd_types.AmdGpuFamily {
    return family;
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

    var buf: [max_pci_devices]pcie.DisplayGfxPciInfo = undefined;
    const n = pcie.collectAmdDisplayDevices(buf[0..], max_scan_bus);
    if (n == 0) {
        if (klog.DEBUG_MODE) klog.info("AMD iGPU: no display-class 1002 device in bus 0..%u", .{max_scan_bus});
        return;
    }

    primary = buf[0];
    probe_ok = true;
    const dev = primary.?;

    family = family_detect.familyFromDeviceId(dev.device_id);

    const mmio = pcie.firstMmioBar(&dev) orelse {
        klog.warn("AMD iGPU: no MMIO BAR (DID=0x%x)", .{dev.device_id});
        probe_ok = false;
        primary = null;
        return;
    };

    mmio_phys = mmio.base;
    mmio_size = mmio.size;
    if (mmio_size == 0 or mmio_phys == 0) {
        klog.warn("AMD iGPU: invalid MMIO BAR", .{});
        probe_ok = false;
        primary = null;
        return;
    }

    mmio_virt = @intCast(mmio_phys);
    mmio_mapped = vm.mapDeviceMmioIdentity(mmio_phys, mmio_size);
    if (!mmio_mapped) {
        klog.warn("AMD iGPU: mapDeviceMmioIdentity failed (phys=0x%x size=0x%x)", .{ mmio_phys, mmio_size });
    }

    display_result = display_handoff.initForFamily(family, mmio_virt, build_options.amd_kms_experimental);

    klog.info("AMD iGPU: DID=0x%x rev=0x%x family=%u bus=%u dev=%u fn=%u MMIO=0x%x size=0x%x", .{
        dev.device_id,
        dev.revision_id,
        @intFromEnum(family),
        dev.loc.bus,
        dev.loc.dev,
        dev.loc.func,
        mmio_phys,
        mmio_size,
    });
    klog.info("AMD iGPU: display_init=%u (handoff path when GOP present)", .{@intFromEnum(display_result)});
}

pub fn ensureDeferredProbeCompleted() void {
    if (!build_options.amd_igpu) return;
    if (!build_options.amd_igpu_defer_probe) return;
    runPciProbeOnce();
}

pub fn resolveDesktopFramebuffer(boot: DesktopFb) DesktopFb {
    ensureDeferredProbeCompleted();
    if (!build_options.amd_igpu or !probe_ok) return boot;
    _ = gmc_stub.installFramebufferGmcStub(mmio_phys, @truncate(boot.addr), @as(usize, boot.pitch) * @as(usize, boot.height));
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
    family = .unknown;
    display_result = .failed;
}

pub fn init() void {
    if (!build_options.amd_igpu) return;
    if (builtin.target.cpu.arch != .x86_64) return;
    if (!pcie.supports_pci_config) return;

    if (build_options.amd_igpu_defer_probe) {
        klog.info("AMD iGPU: PCI/BAR probe deferred until framebuffer resolve (amd_igpu_defer_probe)", .{});
        return;
    }
    runPciProbeOnce();
}
