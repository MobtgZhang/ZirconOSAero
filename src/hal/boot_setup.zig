// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - Unified HAL early boot bring-up

const builtin = @import("builtin");
const arch = @import("../arch.zig");
const klog = @import("../rtl/klog.zig");
const boot = @import("../boot/multiboot2_parse.zig");
const BootInfo = @import("../arch.zig").impl.boot.BootInfo;
const FramebufferInfo = @import("../arch.zig").impl.boot.FramebufferInfo;
const vm = @import("../mm/vm.zig");
const frame = @import("../mm/frame.zig");

pub fn setupVirtQemuKernelSpace(boot_info: *?BootInfo) ?*vm.AddressSpace {
    switch (builtin.target.cpu.arch) {
        .aarch64 => return setupAarch64Virt(boot_info),
        .riscv64 => return setupRiscv64Virt(boot_info),
        else => return null,
    }
}

fn setupAarch64Virt(boot_info: *?BootInfo) ?*vm.AddressSpace {
    var kernel_space: ?vm.AddressSpace = null;
    if (vm.createAddressSpace(frame.kernelFrameAllocatorPtr())) |ks| {
        kernel_space = ks;
        const ksp = &kernel_space.?;
        const id_limit: usize = 2 * 1024 * 1024 * 1024;
        const id_bytes: u64 = @intCast(id_limit);
        const id_stats = vm.mapIdentityByteRange(ksp, 0, id_bytes, .{
            .writable = true,
            .executable = true,
        }) orelse {
            klog.err("AArch64: identity map 0-2GiB failed", .{});
            arch.halt();
        };
        klog.info("VM: AArch64 identity stats huge=%u leaf=%u", .{
            id_stats.huge_pages,
            id_stats.leaf_pages,
        });

        klog.info("AArch64: boot_info ptr=0x%x", .{@intFromPtr(boot_info)});
        if (boot_info.*) |binfo| {
            klog.info("AArch64: boot_info deref ok", .{});
            if (binfo.fb_info) |fb| {
                klog.info("AArch64: fb_info deref ok addr=0x%x", .{fb.addr});
                if (fb.addr != 0 and fb.height > 0 and fb.pitch > 0) {
                    klog.info("AArch64: skipping FB spill (debug; addr=0x%x)", .{fb.addr});
                }
            }
        }
        // Configure TCR_EL1 before MMU activation (traps.init() is Phase 2).
        // 4KB granule, 48-bit VA, 44-bit PA, inner shareable.
        {
            // MAIR_EL1: Attr0 = Normal WB (0xFF), Attr1 = Device-nGnRnE (0x00)
            const mair: u64 = 0x00000000000000FF;
            asm volatile ("msr mair_el1, %[m]"
                :
                : [m] "r" (mair),
            );
            asm volatile ("isb");
            const tcr: u64 =
                (16 << 0) | // T0SZ = 16 (48-bit VA lower range)
                (0b00 << 14) | // TG0 = 4KB
                (16 << 16) | // T1SZ = 16 (48-bit VA upper range)
                (0b10 << 30) | // TG1 = 4KB
                (0b010 << 32) | // IPS = 44-bit PA
                (0b01 << 36) | // TBI0 = no top-byte-ignore
                (0b01 << 38) | // TBI1 = no top-byte-ignore
                (0b11 << 24); // SH1+SH0 = inner shareable
            asm volatile ("msr tcr_el1, %[t]"
                :
                : [t] "r" (tcr),
            );
            asm volatile ("isb");
            klog.info("AArch64: TCR_EL1=0x%x configured pre-activate", .{tcr});
        }
        ksp.activate();
        vm.bindKernelAddressSpace(ksp);
        vm.setSectionLazyCommitFillHook(@import("../mm/section.zig").onLazyCommitFillPage);
        klog.info("VM: AArch64 identity map 0-2GiB (PCI ECAM / VirtIO / RAM; 2MiB blocks where aligned)", .{});
    }

    if (boot_info.*) |*bi| {
        const fb_ok = if (bi.fb_info) |fb|
            (fb.addr != 0 and fb.width >= 640 and fb.height >= 480 and fb.pitch > 0 and fb.bpp == 32)
        else
            false;
        if (!fb_ok) {
            const ramfb = @import("aarch64/ramfb.zig");
            if (ramfb.setup()) |rf| {
                bi.fb_info = .{
                    .addr = rf.addr,
                    .pitch = rf.pitch,
                    .width = rf.width,
                    .height = rf.height,
                    .bpp = rf.bpp,
                    .fb_type = rf.fb_type,
                    .pixel_bgr = 1,
                };
                const reserved = ramfb.framebufferReservedBytes();
                if (reserved > 0) {
                    frame.kernelFrameAllocatorPtr().markPhysRangeUsed(@intCast(rf.addr), reserved);
                }
                klog.info("Display: AArch64 ramfb %ux%u @0x%x (no linear UEFI GOP from boot loader)", .{
                    rf.width,
                    rf.height,
                    @as(usize, @intCast(rf.addr)),
                });
            } else {
                klog.warn("ramfb(a64): no linear FB and fw_cfg ramfb missing — Aero needs QEMU -device ramfb", .{});
            }
        }
    }

    return if (kernel_space) |*space| space else null;
}

fn setupRiscv64Virt(boot_info: *?BootInfo) ?*vm.AddressSpace {
    var kernel_space: ?vm.AddressSpace = null;
    if (vm.createAddressSpace(frame.kernelFrameAllocatorPtr())) |ks| {
        kernel_space = ks;
        const ksp = &kernel_space.?;
        const paging = arch.impl.paging;
        const flags = vm.MapFlags{ .writable = true, .executable = true };
        const low_pages = (2 * 1024 * 1024 * 1024) / paging.page_size;
        const id_limit: usize = @intCast(low_pages * paging.page_size);
        var page: usize = 0;
        while (page < low_pages) : (page += 1) {
            const address: u64 = @intCast(page * paging.page_size);
            _ = ksp.mapPage(address, address, flags);
        }
        const ram_pages = (512 * 1024 * 1024) / paging.page_size;
        page = 0;
        while (page < ram_pages) : (page += 1) {
            const address: u64 = 0x80000000 + @as(u64, @intCast(page * paging.page_size));
            _ = ksp.mapPage(address, address, flags);
        }
        if (boot_info.*) |binfo| {
            if (binfo.fb_info) |fb| {
                if (fb.addr != 0 and fb.height > 0 and fb.pitch > 0) {
                    mapFramebufferSpill(ksp, fb, id_limit, "RISC-V64");
                }
            }
        }
        ksp.activate();
        vm.bindKernelAddressSpace(ksp);
        vm.setSectionLazyCommitFillHook(@import("../mm/section.zig").onLazyCommitFillPage);
        klog.info("VM: RISC-V64 identity map low 2GiB + RAM@0x80000000 (512MiB); fw_cfg for ramfb @0x10100000 mapped in low 2GiB", .{});
    }

    if (boot_info.*) |*bi| {
        const fb_ok = if (bi.fb_info) |fb|
            (fb.addr != 0 and fb.width >= 640 and fb.height >= 480 and fb.pitch > 0 and fb.bpp == 32)
        else
            false;
        if (!fb_ok) {
            const ramfb = @import("riscv64/ramfb.zig");
            if (ramfb.setup()) |rf| {
                bi.fb_info = .{
                    .addr = rf.addr,
                    .pitch = rf.pitch,
                    .width = rf.width,
                    .height = rf.height,
                    .bpp = rf.bpp,
                    .fb_type = rf.fb_type,
                    .pixel_bgr = 1,
                };
                const reserved = ramfb.framebufferReservedBytes();
                if (reserved > 0) {
                    frame.kernelFrameAllocatorPtr().markPhysRangeUsed(@intCast(rf.addr), reserved);
                }
                klog.info("Display: RISC-V64 ramfb %ux%u @0x%x (no linear UEFI GOP from boot loader)", .{
                    rf.width,
                    rf.height,
                    @as(usize, @intCast(rf.addr)),
                });
            } else {
                klog.warn("ramfb(rv): no linear FB and fw_cfg ramfb missing — add -device ramfb", .{});
            }
        }
    }

    return if (kernel_space) |*space| space else null;
}

fn mapFramebufferSpill(space: *vm.AddressSpace, fb: FramebufferInfo, id_limit: usize, platform: []const u8) void {
    const paging = arch.impl.paging;
    const fb_base = @as(usize, @intCast(fb.addr)) & ~@as(usize, paging.page_size - 1);
    const fb_bytes = @as(usize, fb.pitch) * @as(usize, fb.height);
    if (fb_bytes == 0) return;
    const fb_end = fb_base + fb_bytes;
    const va_limit = (fb_end + paging.page_size - 1) & ~@as(usize, paging.page_size - 1);
    const map_lo = @max(fb_base, id_limit);
    if (map_lo >= va_limit) return;
    const flags = vm.MapFlags{ .writable = true, .executable = false, .no_cache = false };
    const length: u64 = @intCast(va_limit - map_lo);
    _ = vm.mapIdentityByteRange(space, @intCast(map_lo), length, flags) orelse {
        klog.err("{s}: framebuffer spill map failed 0x%x", .{ platform, map_lo });
        arch.halt();
    };
    if (fb_base >= id_limit or fb_end > id_limit) {
        klog.info("VM: {s} scanout FB spill 0x{x}..0x{x}", .{ platform, fb_base, fb_end });
    }
}

/// LoongArch64 early boot setup: frame allocator, ramfb, identity map.
/// Replaces the large arch-specific block previously in `boot_generic.zig`.
pub fn setupLoongarchEarlyBoot(
    boot_info: *?BootInfo,
    loong_kernel_space: *?vm.AddressSpace,
    sys_config: anytype,
    build_options: anytype,
) void {
    const bo_w = build_options.kernel_preferred_fb_width;
    const bo_h = build_options.kernel_preferred_fb_height;
    const cw64 = sys_config.getResolutionWidth();
    const ch64 = sys_config.getResolutionHeight();
    var pref_w: u32 = if (cw64 >= 320 and cw64 <= 16384) @truncate(cw64) else bo_w;
    var pref_h: u32 = if (ch64 >= 240 and ch64 <= 16384) @truncate(ch64) else bo_h;
    if (pref_w == 0) pref_w = if (bo_w != 0) bo_w else 1024;
    if (pref_h == 0) pref_h = if (bo_h != 0) bo_h else 768;

    var loong_discarded_gop: ?FramebufferInfo = null;

    if (boot_info.*) |bi_in| {
        var bi_mut = bi_in;
        const gop_ok = if (bi_mut.fb_info) |fb| blk: {
            if (fb.addr == 0 or fb.bpp != 32) break :blk false;
            if (fb.width < 1024 or fb.height < 768) break :blk false;
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
        boot_info.* = bi_mut;
    }

    // Frame allocator init
    const la_k_end = (arch.impl.linkerKernelEndExclusive() + frame.FRAME_SIZE - 1) & ~@as(usize, frame.FRAME_SIZE - 1);
    klog.info("Memory: LoongArch kernel_end=0x%x (_kernel_end aligned)", .{la_k_end});
    frame.initGlobalKernelFrames(boot_info.*, la_k_end);

    const ramfb = @import("loongarch64/ramfb.zig");
    const need_ramfb_scanout = if (boot_info.*) |b|
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
        loong_kernel_space.* = ks;
        const kernel_space = &loong_kernel_space.*.?;
        const identity_pages: usize = (2 * 1024 * 1024 * 1024) / paging.page_size;
        const id_limit: usize = identity_pages * paging.page_size;
        const id_bytes_la: u64 = @as(u64, @intCast(id_limit));
        const la_id_st = vm.mapIdentityByteRange(kernel_space, 0, id_bytes_la, .{ .writable = true, .executable = true }) orelse {
            klog.err("LoongArch: identity map failed (mapIdentityByteRange)", .{});
            arch.halt();
        };
        klog.info("VM: LoongArch identity stats bulk=%u leaf=%u", .{
            la_id_st.bulk_blocks, la_id_st.leaf_pages,
        });
        if (boot_info.*) |binfo| {
            if (binfo.fb_info) |fb_i| {
                if (fb_i.addr != 0 and fb_i.height > 0 and fb_i.pitch > 0) {
                    mapFramebufferSpillUncached(kernel_space, fb_i, id_limit, "LoongArch");
                }
            }
        }
        kernel_space.activate();
        vm.bindKernelAddressSpace(kernel_space);
        vm.setSectionLazyCommitFillHook(@import("../mm/section.zig").onLazyCommitFillPage);
        klog.info("VM: LoongArch identity map 0-2GB (covers GOP fb; BAR>2G via mapDeviceMmioIdentity)", .{});
    }

    const has_gop_fb = if (boot_info.*) |b| (b.fb_info != null and b.fb_info.?.addr != 0) else false;
    if (!has_gop_fb) {
        if (ramfb.setupWithDims(pref_w, pref_h)) |fb_i| {
            var bi = boot_info.* orelse BootInfo{};
            bi.fb_info = .{
                .addr = fb_i.addr,
                .pitch = fb_i.pitch,
                .width = fb_i.width,
                .height = fb_i.height,
                .bpp = fb_i.bpp,
                .fb_type = fb_i.fb_type,
            };
            boot_info.* = bi;
            const rsv = ramfb.framebufferReservedBytesDims(fb_i.width, fb_i.height);
            if (rsv > 0) {
                frame.kernelFrameAllocatorPtr().markPhysRangeUsed(@as(usize, @intCast(fb_i.addr)), rsv);
            }
            klog.info("ramfb: %ux%u@%u addr=0x%x", .{
                fb_i.width,                      fb_i.height, fb_i.bpp,
                @as(usize, @intCast(fb_i.addr)),
            });
        } else {
            klog.warn("ramfb: setupWithDims failed — no framebuffer (check QEMU -device ramfb and fw_cfg etc/ramfb)", .{});
            if (loong_discarded_gop) |dg| {
                if (dg.addr != 0 and dg.bpp == 32 and dg.width >= 1024 and dg.height >= 768) {
                    var bi = boot_info.* orelse BootInfo{};
                    bi.fb_info = dg;
                    boot_info.* = bi;
                    const gop_bytes = @as(usize, dg.pitch) * @as(usize, dg.height);
                    if (gop_bytes > 0) {
                        frame.kernelFrameAllocatorPtr().markPhysRangeUsed(@as(usize, @intCast(dg.addr)), gop_bytes);
                    }
                    klog.warn("LoongArch: restored UEFI GOP %ux%u (ramfb/fw_cfg failed; desktop at firmware res)", .{
                        dg.width, dg.height,
                    });
                }
            }
        }
    } else {
        klog.info("Display: using GOP framebuffer from handoff (same surface as firmware)", .{});
    }
}

/// LoongArch variant: spill map uses `no_cache = true` (uncached) unlike x86/AArch64.
fn mapFramebufferSpillUncached(space: *vm.AddressSpace, fb: FramebufferInfo, id_limit: usize, platform: []const u8) void {
    const paging = arch.impl.paging;
    const fb_base = @as(usize, @intCast(fb.addr)) & ~@as(usize, paging.page_size - 1);
    const fb_bytes = @as(usize, fb.pitch) * @as(usize, fb.height);
    if (fb_bytes == 0) return;
    const fb_end = fb_base + fb_bytes;
    const va_limit = (fb_end + paging.page_size - 1) & ~@as(usize, paging.page_size - 1);
    const map_lo = @max(fb_base, id_limit);
    if (map_lo >= va_limit) return;
    const flags = vm.MapFlags{ .writable = true, .executable = false, .no_cache = true };
    const length: u64 = @intCast(va_limit - map_lo);
    _ = vm.mapIdentityByteRange(space, @intCast(map_lo), length, flags) orelse {
        klog.err("{s}: framebuffer spill map failed 0x{x}", .{ platform, map_lo });
        arch.halt();
    };
    if (fb_base >= id_limit or fb_end > id_limit) {
        klog.info("VM: {s} scanout FB 0x{x}..0x{x} (uncached PTEs)", .{ platform, fb_base, fb_end });
    }
}
