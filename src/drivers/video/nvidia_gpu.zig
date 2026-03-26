//! NVIDIA PCI 显示（10DE，class 0x03）— 阶段一：枚举、BAR0 MMIO 映射、GOP 帧缓冲 handoff。
//!
//! - **非** Windows WDDM / 闭源驱动 ABI；仅内核占位 `\\Driver\\Nvidia`、`\\Device\\Nvidia0`（create/close），供后续 IOCTL 面扩展。
//! - 默认**不写入** PMC / display engine，利于双启动安装 NVIDIA Windows 驱动；GPU 直通虚拟机时建议 `-Dnvidia_gpu=false`。
//!
//! **后续迭代**（`future-nouveau`）：按芯片族拆分 MMIO、VRAM BAR、显示引擎；对照 nouveau `nvkm` 寄存器布局；保留 `nvidia_kms_experimental` 与白名单写路径。

const builtin = @import("builtin");
const build_options = @import("build_options");
const klog = @import("../../rtl/klog.zig");
const vm = @import("../../mm/vm.zig");
const io = @import("../../io/io.zig");
const pcie = @import("../bus/pcie.zig");
const hdmi = @import("hdmi.zig");

const types = @import("nvidia/types.zig");
const chip_class = @import("nvidia/chip_class.zig");
const display_handoff = @import("nvidia/display_handoff_stub.zig");

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
var family: types.NvidiaGpuFamily = .unknown;
var display_result: types.DisplayInitResult = .failed;
var driver_registered: bool = false;
var driver_idx: u32 = 0;

pub fn isActive() bool {
    if (!build_options.nvidia_gpu) return false;
    return probe_ok;
}

pub fn isDeferredProbePending() bool {
    if (!build_options.nvidia_gpu) return false;
    if (!build_options.nvidia_gpu_defer_probe) return false;
    return !probe_ran;
}

fn nvidiaDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

fn registerNvidiaStub() void {
    if (driver_registered) return;
    driver_idx = io.registerDriver("\\Driver\\Nvidia", nvidiaDispatch) orelse {
        klog.warn("NVIDIA: registerDriver \\\\Driver\\\\Nvidia failed", .{});
        return;
    };
    _ = io.createDevice("\\Device\\Nvidia0", .unknown, driver_idx) orelse {
        klog.warn("NVIDIA: createDevice \\\\Device\\\\Nvidia0 failed", .{});
        return;
    };
    driver_registered = true;
    klog.info("NVIDIA: stub \\\\Driver\\\\Nvidia \\\\Device\\\\Nvidia0 (not WDDM; IOCTL TBD)", .{});
}

fn runPciProbeOnce() void {
    if (probe_ran) return;
    probe_ran = true;

    if (builtin.target.cpu.arch != .x86_64) return;
    if (!build_options.nvidia_gpu) return;
    if (!pcie.supports_pci_config) return;

    var buf: [max_pci_devices]pcie.DisplayGfxPciInfo = undefined;
    const n = pcie.collectNvidiaDisplayDevices(buf[0..], max_scan_bus);
    if (n == 0) {
        if (klog.DEBUG_MODE) klog.info("NVIDIA: no display-class 10de device in bus 0..%u", .{max_scan_bus});
        return;
    }

    primary = buf[0];
    probe_ok = true;
    const dev = primary.?;

    family = chip_class.familyFromDeviceId(dev.device_id);

    const mmio = pcie.firstMmioBar(&dev) orelse {
        klog.warn("NVIDIA: no MMIO BAR (DID=0x%x)", .{dev.device_id});
        probe_ok = false;
        primary = null;
        return;
    };

    mmio_phys = mmio.base;
    mmio_size = mmio.size;
    if (mmio_size == 0 or mmio_phys == 0) {
        klog.warn("NVIDIA: invalid MMIO BAR", .{});
        probe_ok = false;
        primary = null;
        return;
    }

    mmio_virt = @intCast(mmio_phys);
    mmio_mapped = vm.mapDeviceMmioIdentity(mmio_phys, mmio_size);
    if (!mmio_mapped) {
        klog.warn("NVIDIA: mapDeviceMmioIdentity failed (phys=0x%x size=0x%x)", .{ mmio_phys, mmio_size });
    }

    display_result = display_handoff.initForFamily(family, mmio_virt, build_options.nvidia_kms_experimental);

    klog.info("NVIDIA: DID=0x%x rev=0x%x family=%u bus=%u dev=%u fn=%u MMIO=0x%x size=0x%x", .{
        dev.device_id,
        dev.revision_id,
        @intFromEnum(family),
        dev.loc.bus,
        dev.loc.dev,
        dev.loc.func,
        mmio_phys,
        mmio_size,
    });
    klog.info("NVIDIA: display_init=%u (GOP handoff when firmware enabled)", .{@intFromEnum(display_result)});
}

pub fn ensureDeferredProbeCompleted() void {
    if (!build_options.nvidia_gpu) return;
    if (!build_options.nvidia_gpu_defer_probe) return;
    runPciProbeOnce();
}

pub fn resolveDesktopFramebuffer(boot: DesktopFb) DesktopFb {
    ensureDeferredProbeCompleted();
    if (!build_options.nvidia_gpu or !probe_ok) return boot;
    if (build_options.nvidia_hdmi_sync) {
        hdmi.syncNvidiaGpuConnector(primary.?.device_id, @intFromEnum(family));
        hdmi.syncFramebufferMode(boot.width, boot.height, boot.bpp);
    }
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
    if (!build_options.nvidia_gpu) return;
    if (builtin.target.cpu.arch != .x86_64) return;
    if (!pcie.supports_pci_config) return;

    registerNvidiaStub();

    if (build_options.nvidia_gpu_defer_probe) {
        klog.info("NVIDIA: PCI/BAR probe deferred until framebuffer resolve (nvidia_gpu_defer_probe)", .{});
        return;
    }
    runPciProbeOnce();
}
