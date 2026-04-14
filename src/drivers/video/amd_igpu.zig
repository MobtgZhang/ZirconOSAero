// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! AMD/ATI 显示控制器：PCI 枚举、BAR 分类、MMIO 映射、固件 GOP handoff（独显 RX550 / Polaris 与 APU 共用）。
//! DID→族见 `amd/dids.zig`、`amd/family_detect.zig`；KMS 见 `amd/display_dc_stub.zig`。

const builtin = @import("builtin");
const build_options = @import("build_options");
const klog = @import("../../rtl/klog.zig");
const vm = @import("../../mm/vm.zig");
const pcie = @import("../bus/pcie.zig");
const hdmi = @import("legacy/hdmi.zig");

const amd_types = @import("vendor/amd/types.zig");
const family_detect = @import("vendor/amd/family_detect.zig");
const display_handoff = @import("vendor/amd/display_handoff.zig");
const gmc = @import("vendor/amd/gmc.zig");
const policy = @import("vendor/amd/policy.zig");
const pcie_bars = @import("vendor/amd/pcie_bars.zig");
const pcie_caps = @import("vendor/amd/pcie_caps.zig");
const pci_dump = @import("vendor/amd/pci_dump.zig");

/// 与 multiboot / UEFI handoff 及 Intel 路径共用布局
pub const DesktopFb = @import("intel_igpu.zig").DesktopFb;

const max_pci_devices: usize = 8;
const max_scan_bus: u8 = 7;

var probe_ok: bool = false;
var probe_ran: bool = false;
var mmio_mapped: bool = false;
var primary: ?pcie.DisplayGfxPciInfo = null;
var mmio_phys: u64 = 0;
var mmio_size: u64 = 0;
var mmio_virt: usize = 0;
var vram_aperture_phys: u64 = 0;
var vram_aperture_size: u64 = 0;
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
        if (klog.DEBUG_MODE) klog.info("AMD display: no display-class 1002 device in bus 0..%u", .{max_scan_bus});
        return;
    }

    const pi = policy.pickPrimaryAmdDisplayIndex(buf[0..n], family_detect.familyFromDeviceId);
    if (n > 1 and klog.DEBUG_MODE) {
        klog.info("AMD display: %u adapter(s), primary index %u", .{ n, pi });
    }

    primary = buf[pi];
    probe_ok = true;
    const dev = primary.?;

    family = family_detect.familyFromDeviceId(dev.device_id);

    pcie_caps.logPciCommandSummary(dev.loc);
    pcie_caps.logStandardCapabilities(dev.loc);
    pcie_caps.logExpansionRomRegister(dev.loc);

    const classified = pcie_bars.classifyAmdDisplayBars(&dev);
    pcie_bars.logBarSummary(&dev, classified);
    vram_aperture_phys = if (classified.vram) |v| v.base else 0;
    vram_aperture_size = if (classified.vram) |v| v.size else 0;

    const mmio = pcie_bars.registerMmioBar(&dev) orelse {
        klog.warn("AMD display: no MMIO BAR (DID=0x%x)", .{dev.device_id});
        pci_dump.logDeviceDump(&dev, "no MMIO BAR");
        probe_ok = false;
        primary = null;
        vram_aperture_phys = 0;
        vram_aperture_size = 0;
        return;
    };

    mmio_phys = mmio.base;
    mmio_size = mmio.size;
    if (mmio_size == 0 or mmio_phys == 0) {
        klog.warn("AMD display: invalid MMIO BAR", .{});
        pci_dump.logDeviceDump(&dev, "invalid MMIO BAR");
        probe_ok = false;
        primary = null;
        vram_aperture_phys = 0;
        vram_aperture_size = 0;
        return;
    }

    mmio_virt = @intCast(mmio_phys);
    mmio_mapped = vm.mapDeviceMmioIdentity(mmio_phys, mmio_size);
    if (!mmio_mapped) {
        klog.warn("AMD display: mapDeviceMmioIdentity failed (phys=0x%x size=0x%x)", .{ mmio_phys, mmio_size });
        pci_dump.logDeviceDump(&dev, "MMIO map failed");
        probe_ok = false;
        primary = null;
        vram_aperture_phys = 0;
        vram_aperture_size = 0;
        return;
    }

    display_result = display_handoff.initForFamily(family, mmio_virt, build_options.amd_kms_experimental);

    klog.info("AMD display: DID=0x%x rev=0x%x family=%u bus=%u dev=%u fn=%u MMIO=0x%x size=0x%x VRAM_AP=0x%x", .{
        dev.device_id,
        dev.revision_id,
        @intFromEnum(family),
        dev.loc.bus,
        dev.loc.dev,
        dev.loc.func,
        mmio_phys,
        mmio_size,
        vram_aperture_phys,
    });
    klog.info("AMD display: display_init=%u (GOP handoff when firmware enabled)", .{@intFromEnum(display_result)});
}

pub fn ensureDeferredProbeCompleted() void {
    if (!build_options.amd_igpu) return;
    if (!build_options.amd_igpu_defer_probe) return;
    runPciProbeOnce();
}

pub fn resolveDesktopFramebuffer(boot: DesktopFb) DesktopFb {
    ensureDeferredProbeCompleted();
    if (!build_options.amd_igpu or !probe_ok) return boot;
    const dev = primary.?;
    hdmi.syncAmdDisplayConnector(dev.device_id, @intFromEnum(family));
    hdmi.syncFramebufferMode(boot.width, boot.height, boot.bpp);
    _ = gmc.installFramebufferGmcStub(.{
        .reg_mmio_phys = mmio_phys,
        .vram_aperture_phys = vram_aperture_phys,
        .vram_aperture_size = vram_aperture_size,
        .fb_phys = @truncate(boot.addr),
        .fb_size = @as(usize, boot.pitch) * @as(usize, boot.height),
    });
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
    vram_aperture_phys = 0;
    vram_aperture_size = 0;
    family = .unknown;
    display_result = .failed;
}

pub fn init() void {
    if (!build_options.amd_igpu) return;
    if (builtin.target.cpu.arch != .x86_64) return;
    if (!pcie.supports_pci_config) return;

    if (build_options.amd_igpu_defer_probe) {
        klog.info("AMD display: PCI/BAR probe deferred until framebuffer resolve (amd_igpu_defer_probe)", .{});
        return;
    }
    runPciProbeOnce();
}
