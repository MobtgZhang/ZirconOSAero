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
//! Non-x86_64 and generic bring-up (split from main.zig).

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
    const subsys = @import("../subsystems/win32/subsystem.zig");
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
    switch (builtin.target.cpu.arch) {
        .aarch64 => {
            klog.info("HandoffDiag(a64): multiboot_magic=0x%x reg_x1=0x%x vec_mb2_phys=0x%x", .{
                magic, info_addr, boot.uefiVectorMb2PhysForDiag(),
            });
        },
        .riscv64 => {
            klog.info("HandoffDiag(rv): multiboot_magic=0x%x reg_a1=0x%x vec_mb2_phys=0x%x (UART MMIO 0x10000000)", .{
                magic, info_addr, boot.uefiVectorMb2PhysForDiag(),
            });
        },
        else => {},
    }

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

    if (builtin.target.cpu.arch == .aarch64) {
        if (boot_info) |bi| {
            klog.info("BootHandoff(a64): mmap_entries=%u mem_upper_kb=%u multiboot_fb=%s", .{
                bi.mmap_entry_count,
                bi.mem_upper_kb,
                if (bi.fb_info != null) "yes" else "no",
            });
        } else {
            klog.warn("BootHandoff(a64): boot.parse returned null", .{});
        }
    }
    if (builtin.target.cpu.arch == .riscv64) {
        if (boot_info) |bi| {
            klog.info("BootHandoff(rv): mmap_entries=%u mem_upper_kb=%u multiboot_fb=%s", .{
                bi.mmap_entry_count,
                bi.mem_upper_kb,
                if (bi.fb_info != null) "yes" else "no",
            });
        } else {
            klog.warn("BootHandoff(rv): boot.parse returned null", .{});
        }
    }

    // LoongArch：尽早初始化帧分配器 + VM，map 2GB 以覆盖 GOP framebuffer（可能 >512MB）
    if (builtin.target.cpu.arch == .loongarch64) {
        // 首选分辨率：`sys_config` 嵌入的 desktop.conf `[resolution]`（由 sync_resolution_config 与 build.conf 对齐）；无效时回退 build_options。
        const bo_w = @import("build_options").kernel_preferred_fb_width;
        const bo_h = @import("build_options").kernel_preferred_fb_height;
        const cw64 = sys_config.getResolutionWidth();
        const ch64 = sys_config.getResolutionHeight();
        var pref_w: u32 = if (cw64 >= 320 and cw64 <= 16384) @truncate(cw64) else bo_w;
        var pref_h: u32 = if (ch64 >= 240 and ch64 <= 16384) @truncate(ch64) else bo_h;
        if (pref_w == 0) pref_w = if (bo_w != 0) bo_w else 1024;
        if (pref_h == 0) pref_h = if (bo_h != 0) bo_h else 768;

        var loong_discarded_gop: ?boot.FramebufferInfo = null;

        // QEMU GTK 往往只扫「固件 GOP」窗口；若 ZBM 已将 GOP SetMode 到 ≥1024×768，handoff 与该窗口同源，应直接使用。
        // 否则丢弃过小/非线性 GOP，由 ramfb.setupWithDims 写 0xF000000（部分 QEMU 配置下窗口仍不跟 ramfb，见文档）。
        if (boot_info) |bi_in| {
            var bi_mut = bi_in;
            const gop_ok = if (bi_mut.fb_info) |fb| blk: {
                if (fb.addr == 0 or fb.bpp != 32) break :blk false;
                if (fb.width < 1024 or fb.height < 768) break :blk false;
                // 与 build.conf / ZBM 首选一致：固件 GOP 常仅为 1024×768；低于首选则改用 ramfb+fw_cfg（常为 1920×1080）
                if (pref_w != 0 and pref_h != 0 and (fb.width < pref_w or fb.height < pref_h)) {
                    klog.info("Display: GOP %ux%u below build preferred %ux%u; ramfb @ RAMFB_PHYS", .{
                        fb.width, fb.height, pref_w, pref_h,
                    });
                    break :blk false;
                }
                break :blk true;
            } else false;
            if (!gop_ok) {
                if (bi_mut.fb_info) |fb| {
                    const skipped_as_below_pref = pref_w != 0 and pref_h != 0 and
                        (fb.width < pref_w or fb.height < pref_h);
                    if (!skipped_as_below_pref) {
                        klog.info("Display: GOP %ux%u not used (min/resolution/bpp); ramfb @ RAMFB_PHYS", .{
                            fb.width, fb.height,
                        });
                    }
                }
                loong_discarded_gop = bi_mut.fb_info;
                bi_mut.fb_info = null;
            } else {
                klog.info("Display: using UEFI GOP %ux%u (meets preferred %ux%u)", .{
                    bi_mut.fb_info.?.width, bi_mut.fb_info.?.height, pref_w, pref_h,
                });
            }
            boot_info = bi_mut;
        }
        // 勿用固定 0x400000：链接脚本下映像+BSS+1MiB 栈后 _kernel_end 常 >4MiB，否则页表帧会分配到内核/栈物理页，identity map 约在 8MiB 处失败。
        // `_kernel_end` 为零尺寸链接器符号：勿用 @intFromPtr(&_)（LoongArch 上可能为 0）；见 arch/loongarch64/mod.zig `linkerKernelEndExclusive`。
        const la_k_end = (arch.impl.linkerKernelEndExclusive() + frame.FRAME_SIZE - 1) & ~@as(usize, frame.FRAME_SIZE - 1);
        klog.info("Memory: LoongArch kernel_end=0x%x (_kernel_end aligned)", .{la_k_end});
        frame.initGlobalKernelFrames(boot_info, la_k_end);

        const ramfb = @import("../hal/loongarch64/ramfb.zig");
        // QEMU ramfb 扫描使用固定 GPA 0x0F000000..；若在此之后才对 `markPhysRangeUsed`，
        // `createAddressSpace` 的页表帧可能已分配到该区间，与屏缓冲重叠 → 缺页/花屏/「无法进桌面」。
        // 仅 1024×768 等与 GOP 一致时保留 handoff、不走 ramfb，故以往不易触发。
        const need_ramfb_scanout = if (boot_info) |b|
            (b.fb_info == null or b.fb_info.?.addr == 0)
        else
            true;
        if (need_ramfb_scanout) {
            const ramfb_rsv = ramfb.framebufferReservedBytesDims(pref_w, pref_h);
            const ramfb_cap = ramfb.maxStandardScanoutReservedBytes();
            const mark_rsv = @max(ramfb_rsv, ramfb_cap);
            if (mark_rsv > 0) {
                frame.kernelFrameAllocatorPtr().markPhysRangeUsed(ramfb.RAMFB_PHYS, mark_rsv);
                ramfb.noteGuestReservedScanout(mark_rsv);
                klog.info("LoongArch: ramfb scanout reserved %u bytes @0x%x (cap %u for runtime IOCTL; before page tables)", .{
                    @as(u32, @truncate(mark_rsv)), ramfb.RAMFB_PHYS, @as(u32, @truncate(ramfb_cap)),
                });
            }
        }

        const paging = arch.impl.paging;
        if (vm.createAddressSpace(frame.kernelFrameAllocatorPtr())) |ks| {
            loong_kernel_space = ks;
            const kernel_space = &loong_kernel_space.?;
            // 0–2GiB：GOP/ramfb；GPU MMIO 若落在 2–4GiB，`vm.mapDeviceMmioIdentity` 会按需建 identity 非缓存映射
            const identity_pages: usize = (2 * 1024 * 1024 * 1024) / paging.page_size;
            const id_limit: usize = identity_pages * paging.page_size;
            const id_bytes_la: u64 = @as(u64, @intCast(id_limit));
            const la_id_st = vm.mapIdentityByteRange(kernel_space, 0, id_bytes_la, .{ .writable = true, .executable = true }) orelse {
                klog.err("LoongArch: identity map failed (mapIdentityByteRange)", .{});
                arch.halt();
            };
            klog.info("VM: LoongArch identity stats la32m=%u leaf=%u", .{
                la_id_st.la_blocks_32m, la_id_st.leaf_pages,
            });
            // virtio-gpu / 部分固件 GOP 帧缓冲落在 PCI BAR（物理地址 ≥2GiB）；仅 map 低 2GiB 时访问桌面会缺页
            if (boot_info) |binfo| {
                if (binfo.fb_info) |fb_i| {
                    if (fb_i.addr != 0 and fb_i.height > 0 and fb_i.pitch > 0) {
                        const fb_base = @as(usize, @truncate(fb_i.addr)) & ~@as(usize, paging.page_size - 1);
                        const fb_bytes = @as(usize, fb_i.pitch) * @as(usize, fb_i.height);
                        if (fb_bytes != 0) {
                            const fb_end = fb_base + fb_bytes;
                            const va_limit = (fb_end + paging.page_size - 1) & ~@as(usize, paging.page_size - 1);
                            const map_lo = @max(fb_base, id_limit);
                            if (map_lo < va_limit) {
                                const fb_flags = vm.MapFlags{ .writable = true, .executable = false, .no_cache = true };
                                const spill_len = @as(u64, @intCast(va_limit - map_lo));
                                _ = vm.mapIdentityByteRange(kernel_space, @as(u64, @intCast(map_lo)), spill_len, fb_flags) orelse {
                                    klog.err("LoongArch: framebuffer spill map failed 0x%x", .{map_lo});
                                    arch.halt();
                                };
                            }
                            if (fb_base >= id_limit or fb_end > id_limit) {
                                klog.info("VM: LoongArch scanout FB 0x%x..0x%x (touched ≥2GiB; extra uncached PTEs)", .{
                                    fb_base, fb_end,
                                });
                            }
                        }
                    }
                }
            }
            kernel_space.activate();
            vm.bindKernelAddressSpace(kernel_space);
            vm.setSectionLazyCommitFillHook(@import("../mm/section.zig").onLazyCommitFillPage);
            klog.info("VM: LoongArch identity map 0-2GB (covers GOP fb; BAR>2G via mapDeviceMmioIdentity)", .{});
        }
        const has_gop_fb = if (boot_info) |b| (b.fb_info != null and b.fb_info.?.addr != 0) else false;
        if (!has_gop_fb) {
            if (ramfb.setupWithDims(pref_w, pref_h)) |fb_i| {
                var bi = boot_info orelse boot.BootInfo{};
                bi.fb_info = .{
                    .addr = fb_i.addr,
                    .pitch = fb_i.pitch,
                    .width = fb_i.width,
                    .height = fb_i.height,
                    .bpp = fb_i.bpp,
                    .fb_type = fb_i.fb_type,
                };
                boot_info = bi;
                const rsv = ramfb.framebufferReservedBytesDims(fb_i.width, fb_i.height);
                if (rsv > 0) {
                    frame.kernelFrameAllocatorPtr().markPhysRangeUsed(@as(usize, @truncate(fb_i.addr)), rsv);
                }
                klog.info("ramfb: %ux%u@%u addr=0x%x", .{
                    fb_i.width,                       fb_i.height, fb_i.bpp,
                    @as(usize, @truncate(fb_i.addr)),
                });
            } else {
                klog.warn("ramfb: setupWithDims failed — no framebuffer (check QEMU -device ramfb and fw_cfg etc/ramfb; see docs/cn/AeroDesktopRuntime.md LoongArch GOP vs ramfb)", .{});
                if (loong_discarded_gop) |dg| {
                    if (dg.addr != 0 and dg.bpp == 32 and dg.width >= 1024 and dg.height >= 768) {
                        var bi = boot_info orelse boot.BootInfo{};
                        bi.fb_info = dg;
                        boot_info = bi;
                        const gop_bytes = @as(usize, dg.pitch) * @as(usize, dg.height);
                        if (gop_bytes > 0) {
                            frame.kernelFrameAllocatorPtr().markPhysRangeUsed(@as(usize, @truncate(dg.addr)), gop_bytes);
                        }
                        klog.warn("LoongArch: restored UEFI GOP %ux%u (ramfb/fw_cfg failed; desktop at firmware res); fb_reserve updated", .{
                            dg.width, dg.height,
                        });
                    }
                }
            }
        } else {
            klog.info("Display: using GOP framebuffer from handoff (same surface as firmware)", .{});
        }
    }

    // LoongArch -kernel 直启无 EFI handoff 时显示 ZBM 风格操作系统选择菜单（串口）
    const zircon_magic: u32 = 0x6372697A;
    const has_handoff = (magic == zircon_magic and info_addr != 0);
    if (builtin.target.cpu.arch == .loongarch64 and !has_handoff) {
        desktop_session.showZbmStyleBootMenu();
    }

    if (builtin.target.cpu.arch != .loongarch64) {
        const k_reserved = (@intFromPtr(&_kernel_end) + 4095) & ~@as(usize, 4095);
        frame.initGlobalKernelFrames(boot_info, k_reserved);
    }

    // QEMU virt：启用自有页表并 identity map，否则 ExitBootServices 后 VirtIO PCI / ECAM 访问不可靠
    var virt_qemu_kernel_space: ?vm.AddressSpace = null;
    if (builtin.target.cpu.arch == .aarch64) {
        const paging = arch.impl.paging;
        if (vm.createAddressSpace(frame.kernelFrameAllocatorPtr())) |ks| {
            virt_qemu_kernel_space = ks;
            const ksp = &virt_qemu_kernel_space.?;
            const id_limit: usize = 2 * 1024 * 1024 * 1024;
            const id_bytes: u64 = @as(u64, @intCast(id_limit));
            const id_st = vm.mapIdentityByteRange(ksp, 0, id_bytes, .{ .writable = true, .executable = true }) orelse {
                klog.err("AArch64: identity map 0-2GiB failed", .{});
                arch.halt();
            };
            klog.info("VM: AArch64 identity stats huge_2m=%u leaf=%u", .{
                id_st.x86_huge_2m, id_st.leaf_pages,
            });
            if (boot_info) |binfo| {
                if (binfo.fb_info) |fb_i| {
                    if (fb_i.addr != 0 and fb_i.height > 0 and fb_i.pitch > 0) {
                        const fb_base = @as(usize, @truncate(fb_i.addr)) & ~@as(usize, paging.page_size - 1);
                        const fb_bytes = @as(usize, fb_i.pitch) * @as(usize, fb_i.height);
                        if (fb_bytes != 0) {
                            const fb_end = fb_base + fb_bytes;
                            const va_limit = (fb_end + paging.page_size - 1) & ~@as(usize, paging.page_size - 1);
                            const map_lo = @max(fb_base, id_limit);
                            if (map_lo < va_limit) {
                                const spill_len = @as(u64, @intCast(va_limit - map_lo));
                                const fb_flags = vm.MapFlags{ .writable = true, .executable = false, .no_cache = false };
                                _ = vm.mapIdentityByteRange(ksp, @as(u64, @intCast(map_lo)), spill_len, fb_flags) orelse {
                                    klog.err("AArch64: framebuffer spill map failed 0x%x", .{map_lo});
                                    arch.halt();
                                };
                            }
                            if (fb_base >= id_limit or fb_end > id_limit) {
                                klog.info("VM: AArch64 scanout FB spill 0x%x..0x%x", .{ fb_base, fb_end });
                            }
                        }
                    }
                }
            }
            ksp.activate();
            vm.bindKernelAddressSpace(ksp);
            vm.setSectionLazyCommitFillHook(@import("../mm/section.zig").onLazyCommitFillPage);
            klog.info("VM: AArch64 identity map 0-2GiB (PCI ECAM / VirtIO / RAM; 2MiB blocks where aligned)", .{});
        }
        // UEFI GOP 在 QEMU AArch64+virtio-gpu 上常为 BLT-only，ZBM 不传 FB tag → 桌面永不启动；用 ramfb 补全。
        if (boot_info) |*bi| {
            const fb_ok = if (bi.fb_info) |fb|
                (fb.addr != 0 and fb.width >= 640 and fb.height >= 480 and fb.pitch > 0 and fb.bpp == 32)
            else
                false;
            if (!fb_ok) {
                const a64_ramfb = @import("../hal/aarch64/ramfb.zig");
                if (a64_ramfb.setup()) |rf| {
                    bi.fb_info = .{
                        .addr = rf.addr,
                        .pitch = rf.pitch,
                        .width = rf.width,
                        .height = rf.height,
                        .bpp = rf.bpp,
                        .fb_type = rf.fb_type,
                        .pixel_bgr = 1,
                    };
                    const rsv = a64_ramfb.framebufferReservedBytes();
                    if (rsv > 0) {
                        frame.kernelFrameAllocatorPtr().markPhysRangeUsed(@as(usize, @truncate(rf.addr)), rsv);
                    }
                    klog.info("Display: AArch64 ramfb %ux%u @0x%x (no linear UEFI GOP from boot loader)", .{
                        rf.width, rf.height, @as(usize, @truncate(rf.addr)),
                    });
                } else {
                    klog.warn("ramfb(a64): no linear FB and fw_cfg ramfb missing — Aero needs QEMU -device ramfb (see Makefile QEMU_AARCH64_DEVICES)", .{});
                }
            }
        }
    } else if (builtin.target.cpu.arch == .riscv64) {
        const paging = arch.impl.paging;
        if (vm.createAddressSpace(frame.kernelFrameAllocatorPtr())) |ks| {
            virt_qemu_kernel_space = ks;
            const ksp = &virt_qemu_kernel_space.?;
            const flags = vm.MapFlags{ .writable = true, .executable = true };
            const n_low = (2 * 1024 * 1024 * 1024) / paging.page_size;
            const id_limit: usize = n_low * paging.page_size;
            var ip: usize = 0;
            while (ip < n_low) : (ip += 1) {
                const v = ip * paging.page_size;
                _ = ksp.mapPage(v, v, flags);
            }
            const ram_pages = (512 * 1024 * 1024) / paging.page_size;
            ip = 0;
            while (ip < ram_pages) : (ip += 1) {
                const v = 0x80000000 + ip * paging.page_size;
                _ = ksp.mapPage(v, v, flags);
            }
            if (boot_info) |binfo| {
                if (binfo.fb_info) |fb_i| {
                    if (fb_i.addr != 0 and fb_i.height > 0 and fb_i.pitch > 0) {
                        const fb_base = @as(usize, @truncate(fb_i.addr)) & ~@as(usize, paging.page_size - 1);
                        const fb_bytes = @as(usize, fb_i.pitch) * @as(usize, fb_i.height);
                        if (fb_bytes != 0) {
                            const fb_end = fb_base + fb_bytes;
                            const va_limit = (fb_end + paging.page_size - 1) & ~@as(usize, paging.page_size - 1);
                            const map_lo = @max(fb_base, id_limit);
                            if (map_lo < va_limit) {
                                const spill_len = @as(u64, @intCast(va_limit - map_lo));
                                const fb_flags = vm.MapFlags{ .writable = true, .executable = false, .no_cache = false };
                                _ = vm.mapIdentityByteRange(ksp, @as(u64, @intCast(map_lo)), spill_len, fb_flags) orelse {
                                    klog.err("RISC-V64: framebuffer spill map failed 0x%x", .{map_lo});
                                    arch.halt();
                                };
                            }
                            if (fb_base >= id_limit or fb_end > id_limit) {
                                klog.info("VM: RISC-V64 scanout FB spill 0x%x..0x%x", .{ fb_base, fb_end });
                            }
                        }
                    }
                }
            }
            ksp.activate();
            vm.bindKernelAddressSpace(ksp);
            vm.setSectionLazyCommitFillHook(@import("../mm/section.zig").onLazyCommitFillPage);
            klog.info("VM: RISC-V64 identity map low 2GiB + RAM@0x80000000 (512MiB); fw_cfg for ramfb @0x10100000 mapped in low 2GiB", .{});
        }
        if (boot_info) |*bi| {
            const fb_ok = if (bi.fb_info) |fb|
                (fb.addr != 0 and fb.width >= 640 and fb.height >= 480 and fb.pitch > 0 and fb.bpp == 32)
            else
                false;
            if (!fb_ok) {
                const rv_ramfb = @import("../hal/riscv64/ramfb.zig");
                if (rv_ramfb.setup()) |rf| {
                    bi.fb_info = .{
                        .addr = rf.addr,
                        .pitch = rf.pitch,
                        .width = rf.width,
                        .height = rf.height,
                        .bpp = rf.bpp,
                        .fb_type = rf.fb_type,
                        .pixel_bgr = 1,
                    };
                    const rsv = rv_ramfb.framebufferReservedBytes();
                    if (rsv > 0) {
                        frame.kernelFrameAllocatorPtr().markPhysRangeUsed(@as(usize, @truncate(rf.addr)), rsv);
                    }
                    klog.info("Display: RISC-V64 ramfb %ux%u @0x%x (no linear UEFI GOP from boot loader)", .{
                        rf.width, rf.height, @as(usize, @truncate(rf.addr)),
                    });
                } else {
                    klog.warn("ramfb(rv): no linear FB and fw_cfg ramfb missing — add -device ramfb (see Makefile QEMU_RISCV64_EXTRA)", .{});
                }
            }
        }
    }
    if (boot_info) |info| {
        klog.info("Memory: upper=%u KB, mmap_entries=%u", .{
            info.mem_upper_kb, info.mmap_entry_count,
        });
        klog.info("Boot: mode=%u desktop_theme=%u (EFI handoff if magic matches)", .{
            @intFromEnum(info.boot_mode), @intFromEnum(info.desktop_theme),
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
    if (builtin.target.cpu.arch == .loongarch64) {
        arch.impl.traps.init();
    }
    if (builtin.target.cpu.arch == .riscv64) {
        arch.impl.traps.init();
    }
    if (builtin.target.cpu.arch == .aarch64) {
        arch.impl.traps.init();
    }
    timer.init();
    if (builtin.target.cpu.arch == .loongarch64) {
        arch.enableInterrupts();
        klog.info("LoongArch: CRMD.IE enabled (timer + HWI)", .{});
    }
    if (builtin.target.cpu.arch == .riscv64) {
        arch.enableInterrupts();
        klog.info("RISC-V64: sstatus.SIE enabled (timer + PLIC)", .{});
    }
    if (builtin.target.cpu.arch == .aarch64) {
        arch.enableInterrupts();
        klog.info("AArch64: DAIF.IRQ enabled (GIC timer + peripherals)", .{});
    }

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

    if (builtin.target.cpu.arch == .x86_64) {
        drivers_generic.storage.boot_probe.mountBootProbeIfReady();
    }
    virtio_blk_scratch_fs.mountIfVirtioBlkDetected();
    if (builtin.target.cpu.arch == .x86_64) {
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
    subsys.init();
    exec.init();

    klog.info("--- Phase 10: Graphical Subsystem ---", .{});
    user32_mod.init();
    gdi32_mod.init();
    dwmapi_mod.ensureLinked();
    subsys.initGuiSubsystem();

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

    cmd_mod.runBootSequence();
    exec.runDemoApps();
    gdi32_mod.runGdiDemo();
    user32_mod.runGuiDemo();
    wow64_mod.runWow64Demo();

    klog.info("", .{});
    klog.info("=== System Ready ===", .{});
    klog.info("", .{});

    cmd_mod.runInteractiveShell();
}
