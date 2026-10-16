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

// SPDX-License-Identifier: MIT OR Apache-2.0
//! Generic platform bring-up (split from main.zig; arch-specific logic is in HAL).

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("../arch.zig");
const klog = @import("../rtl/klog.zig");
const desktop_session = @import("desktop_session.zig");

extern const _kernel_end: u8;

pub fn start(magic: u32, info_addr: usize) noreturn {
    const boot = arch.impl.boot;
    const vm = @import("../mm/vm.zig");
    var loong_kernel_space: ?vm.AddressSpace = null;
    const frame = @import("../mm/frame.zig");
    const heap = @import("../mm/heap.zig");
    const heap_boot = @import("../mm/heap_boot.zig");
    const server = @import("../servers/server.zig");
    const smss = @import("../servers/smss.zig");
    const ob = @import("../ob/object.zig");
    const se = @import("../se/token.zig");
    const io = @import("../io/io.zig");
    const scheduler = @import("../ke/scheduler.zig");
    const timer = @import("../ke/timer.zig");
    const port = @import("../lpc/port.zig");
    const vfs_mod = @import("../fs/vfs.zig");
    const fat32_mod = @import("../fs/fat32.zig");
    const ntfs_mod = @import("../fs/ntfs.zig");
    const pe_loader = @import("../loader/pe.zig");
    const elf_loader = @import("../loader/elf.zig");
    const ntdll = @import("../libs/ntdll.zig");
    const kernel32 = @import("../libs/kernel32.zig");
    const console_mod = @import("../subsystems/win32/console.zig");
    const cmd_mod = @import("../subsystems/win32/cmd.zig");
    const subsys_cmd = @import("../subsystems/win32/subsystem.zig");
    const exec = @import("../subsystems/win32/exec.zig");
    const user32_mod = @import("../subsystems/win32/user32.zig");
    const gdi32_mod = @import("../subsystems/win32/gdi32.zig");
    const dwmapi_mod = @import("../subsystems/win32/dwmapi.zig");
    const wow64_mod = @import("../subsystems/win32/wow64.zig");
    const sys_config = @import("../config/config.zig");
    const audio = @import("../drivers/audio/audio.zig");
    const registry = @import("../registry/registry.zig");
    const virtio_blk_scratch_fs = @import("../drivers/storage/virtio_blk_scratch_fs.zig");

    arch.initSerial();

    // 极早 handoff 诊断（UEFI→内核）：区分「未进内核」与「进内核后崩溃」；与 ZBM 写入的 mb2_phys 对照。
    klog.info("HandoffDiag: multiboot_magic=0x%x info_addr=0x%x vec_mb2_phys=0x%x", .{
        magic, info_addr, boot.uefiVectorMb2PhysForDiag(),
    });

    klog.info("========================================", .{});
    klog.info("  ZirconOSAero (NT 6.1 hybrid kernel)", .{});
    klog.info("  Architecture: %s", .{arch.impl.name});
    klog.info("========================================", .{});

    if (klog.DEBUG_MODE) {
        klog.info("Build: DEBUG mode (verbose logging enabled)", .{});
    } else {
        klog.info("Build: RELEASE mode (optimized)", .{});
    }

    klog.info("--- Loading System Configuration ---", .{});
    sys_config.init();
    klog.info("Config: %u total entries loaded", .{sys_config.getTotalConfigEntries()});

    klog.info("--- Phase 1: Boot + Early Kernel ---", .{});

    var boot_info = boot.parse(magic, info_addr);

    if (boot_info) |bi| {
        klog.info("BootHandoff: mmap_entries=%u mem_upper_kb=%u multiboot_fb=%s", .{
            bi.mmap_entry_count,
            bi.mem_upper_kb,
            if (bi.fb_info != null) "yes" else "no",
        });
    } else {
        klog.warn("BootHandoff: boot.parse returned null", .{});
    }

    const hal = @import("../hal.zig");

    // LoongArch：尽早初始化帧分配器 + VM（HAL 封装，boot_generic 不再引用架构）
    if (hal.hasLoongsonIGPU) {
        const hal_boot_la = @import("../hal/boot_setup.zig");
        hal_boot_la.setupLoongarchEarlyBoot(&boot_info, &loong_kernel_space, sys_config, @import("build_options"));
    }

    // LoongArch -kernel 直启无 EFI handoff 时显示 ZBM 风格操作系统选择菜单（串口）
    const zircon_magic: u32 = 0x6372697A;
    const has_handoff = (magic == zircon_magic and info_addr != 0);
    if (hal.requiresSerialBootMenuWithoutHandoff() and !has_handoff) {
        desktop_session.showZbmStyleBootMenu();
    }

    if (hal.requiresEarlyKernelFrameReservation()) {
        const k_reserved = (@intFromPtr(&_kernel_end) + 4095) & ~@as(usize, 4095);
        frame.initGlobalKernelFrames(boot_info, k_reserved);
    }

    // QEMU virt：启用自有页表并 identity map，否则 ExitBootServices 后 VirtIO PCI / ECAM 访问不可靠
    const hal_boot = @import("../hal/boot_setup.zig");
    const virt_qemu_kernel_space: ?*vm.AddressSpace = hal_boot.setupVirtQemuKernelSpace(&boot_info);
    _ = virt_qemu_kernel_space;
    if (boot_info) |info| {
        klog.info("Memory: upper=%u KB, mmap_entries=%u", .{
            info.mem_upper_kb, info.mmap_entry_count,
        });
        klog.info("Boot: mode=%u desktop_theme=%u (EFI handoff if magic matches)", .{
            @backingInt(info.boot_mode), @backingInt(info.desktop_theme),
        });
    }

    klog.info("Frame allocator: total_frames=%u, frame_size=%u", .{
        frame.kernelFrameAllocatorPtr().total_frames, frame.FRAME_SIZE,
    });

    const heap_kb_gen: u64 = @min(sys_config.getHeapSizeKb(), @as(u64, 512 * 1024));
    const heap_kb_gen32: u32 = @truncate(@min(heap_kb_gen, @as(u64, std.math.maxInt(u32))));
    if (vm.kernelAddressSpace()) |ks| {
        heap_boot.initKernelHeapAfterVm(ks, heap_kb_gen32);
    } else {
        heap.init();
    }
    klog.info("Kernel heap: growable=%u base=0x%x cap=%uKB committed=%uB live=%uB", .{
        @intFromBool(heap.isGrowableBacked()),
        heap.kernelHeapBaseVirt(),
        heap.capacityBytes() / 1024,
        heap.totalBytes(),
        heap.usedBytes(),
    });

    const ex_pool_gen = @import("../mm/ex_pool.zig");
    const irql_gen = @import("../ke/irql.zig");
    ex_pool_gen.setPagedPoolIrqlGuard(irql_gen.assertBelowDispatchForPagedPool);

    const phys_buddy = @import("../mm/phys_buddy.zig");
    phys_buddy.initKernelContiguousBuddy(frame.kernelFrameAllocatorPtr());
    if (phys_buddy.kernelContiguousBuddyReady()) {
        klog.info("PhysBuddy: leaf_pages=%u", .{phys_buddy.kernelContiguousLeafPages()});
    } else {
        klog.warn("PhysBuddy: contiguous carve unavailable", .{});
    }

    klog.info("--- Phase 2: Scheduler + Timer ---", .{});
    scheduler.init();
    @import("../ke/apc.zig").init();
    arch.initTraps();
    timer.init();
    @import("../hal.zig").enableBringupInterrupts();

    klog.info("--- Phase 4: Object / Handle / Process Core ---", .{});
    ob.init();
    ob.initNamespace();
    @import("../mm/section.zig").registerSectionCleanupHook();
    se.init();
    io.init();

    klog.info("--- Phase 5: IPC + System Services ---", .{});
    server.init(frame.kernelFrameAllocatorPtr());
    _ = port.createPort(1, "\\LPC\\PsServer");
    _ = port.createPort(1, "\\LPC\\ObServer");
    _ = port.createPort(1, "\\LPC\\IoServer");
    smss.init(frame.kernelFrameAllocatorPtr());

    klog.info("--- Phase 6: I/O + File + Driver ---", .{});
    const drivers_generic = @import("../drivers/mod.zig");
    drivers_generic.init();
    drivers_generic.initInputDrivers();
    drivers_generic.initAudioDrivers();
    vfs_mod.init();
    fat32_mod.init();
    ntfs_mod.init();

    // Initialize and mount InitFS (RAM-based Windows filesystem)
    const initfs_mod = @import("../fs/initfs.zig");
    initfs_mod.init();
    if (initfs_mod.mountAsDrive('C') == .success) {
        klog.info("InitFS: C: drive mounted successfully", .{});
    } else {
        klog.warn("InitFS: Failed to mount C: drive", .{});
    }

    if (comptime @import("../hal.zig").supportsBootStorageProbe()) {
        drivers_generic.storage.boot_probe.mountBootProbeIfReady();
    }
    virtio_blk_scratch_fs.mountIfVirtioBlkDetected();
    if (comptime @import("../hal.zig").supportsBootStorageProbe()) {
        const virtio_blk = drivers_generic.storage.virtio_blk_pci;
        if (virtio_blk.isVirtioBlkPciPresent()) {
            var head: [32]u8 = undefined;
            if (virtio_blk.submitReadSectors(0, &head) == io.STATUS_SUCCESS) {
                klog.info("STORAGE: VirtIO-blk IRP sector0 read OK", .{});
            }
        }
    }

    registry.init();
    @import("../registry/hive.zig").tryLoadBootstrapOverlays();
    klog.info("Registry: %u keys in 5 hives", .{registry.getKeyCount()});
    drivers_generic.input.mouse.syncFromRegistry();

    klog.info("--- Phase 7: Loader ---", .{});
    elf_loader.init();
    pe_loader.init();

    klog.info("--- Phase 8: Native Userland ---", .{});
    ntdll.init();
    kernel32.init();
    console_mod.init();
    cmd_mod.init();

    klog.info("--- Phase 9: Win32 Subsystem ---", .{});
    subsys_cmd.init();
    exec.init();

    klog.info("--- Phase 10: Graphical Subsystem ---", .{});
    user32_mod.init();
    gdi32_mod.init();
    dwmapi_mod.ensureLinked();
    subsys_cmd.initGuiSubsystem();

    klog.info("--- Phase 11: WOW64 + Audio ---", .{});
    wow64_mod.init();
    audio.init();

    klog.info("", .{});
    klog.info("=== ZirconOSAero NT %s kernel ready (Phase 0–12) ===", .{sys_config.getVersion()});
    klog.info("Architecture : %s", .{arch.impl.name});
    klog.info("Processes    : %u", .{@import("../ps/process.zig").getProcessCount()});
    klog.info("Sessions     : %u", .{smss.getSessionCount()});
    klog.info("Heap         : %u/%u bytes used", .{ heap.usedBytes(), heap.totalBytes() });
    klog.info("I/O Devices  : %u, Drivers: %u", .{ io.getDeviceCount(), io.getDriverCount() });
    klog.info("", .{});

    audio.playEvent(.startup);

    const boot_mode: boot.BootMode = if (boot_info) |info| info.boot_mode else .normal;
    var desktop_theme: boot.DesktopTheme = if (boot_info) |info| info.desktop_theme else .none;
    if (desktop_theme == .none) {
        desktop_theme = desktop_session.desktopThemeFromBuildDefault(@import("build_options").default_desktop);
    }
    var has_gfx_fb = false;
    if (boot_info) |info| {
        if (info.fb_info) |fb_i| {
            if (fb_i.fb_type != 2 and fb_i.width > 0 and fb_i.height > 0 and fb_i.bpp > 0) has_gfx_fb = true;
        }
    }
    klog.info("Display: has_gfx_fb=%u desktop=%s", .{
        @intFromBool(has_gfx_fb),
        desktop_session.desktopThemeName(desktop_theme),
    });

    if (boot_mode == .desktop or (boot_mode == .normal and has_gfx_fb and desktop_theme != .none)) {
        desktop_session.enterDesktopSession(
            frame.kernelFrameAllocatorPtr(),
            boot_info,
            desktop_theme,
            true,
            false,
            false,
            "desktop_generic",
            "Desktop: isDesktopReady=false",
        );
    }

    // CMD.EXE 是用户空间进程（目标 §6-8）：注册到进程表并在其上下文中运行。
    const ps_proc = @import("../ps/process.zig");
    const cmd_alloc = frame.kernelFrameAllocatorPtr();

    if (ps_proc.createSystemProcess(cmd_alloc, "cmd.exe")) |cmd_proc| {
        ps_proc.setCurrentProcess(cmd_proc.pid);
        _ = subsys_cmd.registerProcess(cmd_proc.pid, .win32_cui, "cmd.exe", 0);
        cmd_mod.runBootSequence();
    } else {
        cmd_mod.runBootSequence();
    }
    exec.runDemoApps();
    gdi32_mod.runGdiDemo();
    user32_mod.runGuiDemo();
    wow64_mod.runWow64Demo();

    klog.info("", .{});
    klog.info("=== System Ready ===", .{});
    klog.info("", .{});

    // 交互式 shell 运行在 cmd.exe 进程上下文中（用户空间命令提示符）。
    cmd_mod.runInteractiveShell();
}
