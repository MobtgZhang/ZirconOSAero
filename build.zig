const std = @import("std");
const mem = std.mem;
const wr = @import("tooling/wallpaper_resolution.zig");

const PreferredFbDims = wr.PreferredFbDims;
const parseResolutionFromBuildConfText = wr.parseResolutionFromBuildConfText;
const readPreferredFbFromSyncArtifact = wr.readPreferredFbFromSyncArtifact;
const tryReadPreferredFbFromBuildConf = wr.tryReadPreferredFbFromBuildConf;
const ensureWallpaperPngAssetsPresent = wr.ensureWallpaperPngAssetsPresent;
const wallpaper_png_inputs = wr.wallpaper_png_inputs;

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    ensureWallpaperPngAssetsPresent(b);

    // AArch64 / RISC-V64：内核与 ZBM 由 zig 构建；QEMU 下完整 UEFI 链路为 Makefile（`make run-aarch64` / `make run-riscv64`，含固件与 esp-*.img）。
    const arch_opt = b.option(
        []const u8,
        "arch",
        "Target architecture (x86_64, loongarch64, aarch64, riscv64, mips64el)",
    ) orelse "x86_64";
    const debug_mode = b.option(bool, "debug", "Enable debug mode (verbose klog, serial output)") orelse false;
    const mouse_debug_opt = b.option(
        bool,
        "mouse_debug",
        "MOUSEDBG: always log pointer coords + VirtIO queue snapshot (serial); status bar shows ptr x,y",
    ) orelse false;
    const agent_ndjson_opt = b.option(
        bool,
        "agent_ndjson",
        "Serial lines AGENT_LOG:{...} NDJSON for host ingest (.cursor/debug-*.log via scripts/agent-ingest-serial.sh)",
    ) orelse false;
    const desktop_bisect_opt = b.option(
        bool,
        "desktop_bisect",
        "Serial klog.debug before/after renderDesktopFrameEx and present (panic isolation; default off)",
    ) orelse false;
    const desktop_full_opt = b.option(
        bool,
        "desktop-full",
        "Optional extended desktop/DWM paths (user32 hook; default off; bisect heavy shell changes)",
    ) orelse false;
    const desktop_shell_no_caption_partial_opt = b.option(
        bool,
        "desktop_shell_no_caption_partial",
        "Diagnostics: never use caption-only partial shell repaint (forces full shell layer; bisect black-border / save-under)",
    ) orelse false;
    const desktop_bisect_force_full_present_opt = b.option(
        bool,
        "desktop_bisect_force_full_present",
        "Diagnostics: always fb.flip() full memcpy on double-buffer present (bisect partial flipDirty vs pointer/window darken)",
    ) orelse false;
    const desktop_bisect_disable_cursor_move_only_opt = b.option(
        bool,
        "desktop_bisect_disable_cursor_move_only",
        "Diagnostics: never use cursor_plane.moveOnly (bisect save-under / pointer-fast path vs darken)",
    ) orelse false;
    const dwm_blur_stats_opt = b.option(
        bool,
        "dwm_blur_stats",
        "Per-frame klog.debug: box blur calls, budget denials, renderGlassTintOnly calls (default off)",
    ) orelse false;
    const ps2_mouse_with_virtio_opt = b.option(
        bool,
        "ps2_mouse_with_virtio",
        "x86_64: handle IRQ12 PS/2 mouse even when VirtIO-Input is active (default false; QEMU 双源叠加风险；真机单 PS/2 时可开)",
    ) orelse false;
    const force_gop_present_opt = b.option(
        bool,
        "force_gop_present",
        "Keep GOP/linear framebuffer as active present backend even when VirtIO-GPU scanout is active (diagnostics / A-B compare)",
    ) orelse false;
    const enable_idt_opt = b.option(bool, "enable_idt", "Enable IDT, timer and syscall (x86_64 only)") orelse true;
    const lapic_periodic_tick_opt = b.option(
        bool,
        "lapic_periodic_tick",
        "x86_64: use LAPIC LVT periodic timer (mask PIC IRQ0) after Phase 3 identity + MADT",
    ) orelse false;
    const smp_tlb_ipi_opt = b.option(
        bool,
        "smp_tlb_ipi",
        "x86_64: broadcast fixed IPI (vector 254) on global TLB flush (AP must have IDT stub)",
    ) orelse mem.eql(u8, arch_opt, "x86_64");
    const aero_skip_ico_build = b.option(bool, "aero-skip-ico-build", "For aero-shell-icons-dll: skip SVG→ICO script (reuse existing ico/)") orelse false;
    const aero_windres_exe = b.option([]const u8, "aero-windres", "windres executable for zircon_shell32_res.rc") orelse "x86_64-w64-mingw32-windres";
    // Reserved for Tier 2: real `zircon_shell32_res.dll` for loongarch64-windows-gnu when Zig emits COFF for that triple.
    const aero_la_pe_dll = b.option(
        bool,
        "aero-la-pe-dll",
        "Reserved: enable LoongArch PE shell icon DLL when toolchain supports it (default false; use aero-shell-icons-la-bundle today)",
    ) orelse false;
    _ = aero_la_pe_dll;
    const amd_igpu_opt = b.option(
        bool,
        "amd_igpu",
        "x86_64: probe AMD/ATI display (1002:03xx PCI/MMIO + GOP handoff); Polaris/RX550 + APU; BAR classify reg vs VRAM; QEMU -vga std has no AMD GPU",
    ) orelse true;
    const amd_igpu_defer_probe_opt = b.option(
        bool,
        "amd_igpu_defer_probe",
        "x86_64: run AMD PCI/BAR probe on first resolveDesktopFramebuffer (after GOP handoff)",
    ) orelse false;
    const amd_kms_experimental_opt = b.option(
        bool,
        "amd_kms_experimental",
        "AMD: allow optional MMIO display probe path (default handoff-only; unsafe on some platforms)",
    ) orelse false;
    const intel_igpu_opt = b.option(
        bool,
        "intel_igpu",
        "x86_64: probe Intel integrated GPU (PCI/MMIO + GOP handoff); default on alongside AMD (resolve chain Intel before AMD)",
    ) orelse true;
    const intel_igpu_defer_probe_opt = b.option(
        bool,
        "intel_igpu_defer_probe",
        "x86_64: run Intel PCI/BAR probe on first resolveDesktopFramebuffer (after GOP handoff) to reduce firmware race risk",
    ) orelse false;
    const intel_kms_experimental_opt = b.option(
        bool,
        "intel_kms_experimental",
        "Intel: allow optional MMIO display probe path (default handoff-only; unsafe on some platforms)",
    ) orelse false;
    const nvidia_gpu_opt = b.option(
        bool,
        "nvidia_gpu",
        "x86_64: probe NVIDIA display (10DE:03xx PCI/MMIO + GOP handoff); QEMU -vga std has no NVIDIA GPU",
    ) orelse true;
    const nvidia_gpu_defer_probe_opt = b.option(
        bool,
        "nvidia_gpu_defer_probe",
        "x86_64: run NVIDIA PCI/BAR probe on first resolveDesktopFramebuffer (after GOP handoff)",
    ) orelse false;
    const nvidia_kms_experimental_opt = b.option(
        bool,
        "nvidia_kms_experimental",
        "NVIDIA: optional MMIO peek in diagnostics (default off; no display engine writes)",
    ) orelse false;
    const nvidia_hdmi_sync_opt = b.option(
        bool,
        "nvidia_hdmi_sync",
        "NVIDIA: refresh HDMI stub primary connector when probe_ok (default false: avoid overwriting Intel/AMD metadata on hybrid)",
    ) orelse false;
    const desktop_idle_spin_opt = b.option(
        bool,
        "desktop_idle_spin",
        "x86_64 desktop loop: spin instead of sti;hlt (smoother input polling in QEMU; higher guest CPU use; Makefile DESKTOP_IDLE_SPIN)",
    ) orelse true;
    const get_message_yield_spins_raw = b.option(
        u32,
        "get_message_yield_spins",
        "NtUserGetMessage cooperative loop: max yield/spin iterations before STATUS_PENDING (default 4096; clamp 1..16_777_216)",
    ) orelse 4096;
    const get_message_yield_spins: u32 = switch (get_message_yield_spins_raw) {
        1...16_777_216 => get_message_yield_spins_raw,
        else => blk: {
            std.log.err("Invalid -Dget_message_yield_spins={d}; allowed 1..16777216 — using 4096", .{get_message_yield_spins_raw});
            break :blk 4096;
        },
    };
    const aero_blur_light_opt = b.option(
        bool,
        "aero_blur_light",
        "Reduce default Aero glass box-blur radius/passes (high-res QEMU); Makefile AERO_BLUR_LIGHT",
    ) orelse false;
    var cpu_arch: std.Target.Cpu.Arch = .x86_64;
    if (mem.eql(u8, arch_opt, "x86_64")) {
        cpu_arch = .x86_64;
    } else if (mem.eql(u8, arch_opt, "loongarch64")) {
        cpu_arch = .loongarch64;
    } else if (mem.eql(u8, arch_opt, "aarch64")) {
        cpu_arch = .aarch64;
    } else if (mem.eql(u8, arch_opt, "riscv64")) {
        cpu_arch = .riscv64;
    } else if (mem.eql(u8, arch_opt, "mips64el")) {
        cpu_arch = .mips64el;
    } else {
        @panic("Unsupported arch; expected: x86_64, loongarch64, aarch64, riscv64, mips64el");
    }

    const usb_xhci_opt = b.option(
        bool,
        "usb_xhci",
        "Probe PCI xHCI (USB3/2) and run minimal enumeration + HID boot mouse poll (QEMU-friendly; MVP)",
    ) orelse (cpu_arch == .x86_64);
    const usb_ehci_opt = b.option(
        bool,
        "usb_ehci",
        "Probe EHCI when no xHCI (stub driver: log only until QH/qTD implemented)",
    ) orelse false;

    const loongson_igpu_opt = b.option(
        bool,
        "loongson_igpu",
        "loongarch64: probe Loongson PCI display (vendor 0014) + MMIO map; framebuffer stays UEFI GOP / ramfb until KMS",
    ) orelse (cpu_arch == .loongarch64);
    const loongson_igpu_defer_probe_opt = b.option(
        bool,
        "loongson_igpu_defer_probe",
        "loongarch64: run Loongson PCI/BAR probe on first resolveDesktopFramebuffer",
    ) orelse false;
    const loongson_kms_experimental_opt = b.option(
        bool,
        "loongson_kms_experimental",
        "Loongson: allow future MMIO display probe paths (default handoff-only)",
    ) orelse false;

    // Zig 0.15.x：x86_64 内核在 `-ODebug` 下 `build-exe` 链接阶段会异常退出（LLVM/自托管链接器崩溃）。
    // 将内核实际编译档位升为 ReleaseSafe；`-Ddebug` 仍控制运行时 klog，与 `-Doptimize` 解耦。
    const kernel_optimize: std.builtin.OptimizeMode = blk: {
        if (cpu_arch == .x86_64 and optimize == .Debug) {
            const zv = @import("builtin").zig_version;
            if (zv.major == 0 and zv.minor == 15) {
                break :blk .ReleaseSafe;
            }
        }
        break :blk optimize;
    };

    // x86_64 内核：禁用 SIMD + soft-float（见 zig-nt61-project-core.mdc）。仅当实际优化档位非 Debug 时启用：
    // `-ODebug`（含上面对 Zig 0.15 升格后的 ReleaseSafe）下 Zig 仍会生成需 SSE 的 IR，与 feature 冲突 → `x86_64_encoder: movups`。
    const freestanding_query: std.Target.Query = blk: {
        var q: std.Target.Query = .{
            .cpu_arch = cpu_arch,
            .os_tag = .freestanding,
            .abi = .none,
        };
        if (cpu_arch == .x86_64 and kernel_optimize != .Debug) {
            q.cpu_features_sub = std.Target.x86.featureSet(&.{
                .mmx, .sse,  .sse2,    .sse3, .ssse3, .sse4_1, .sse4_2,
                .avx, .avx2, .avx512f,
            });
            q.cpu_features_add = std.Target.x86.featureSet(&.{.soft_float});
        }
        break :blk q;
    };
    const target = b.resolveTargetQuery(freestanding_query);

    const zigimg_dep = b.dependency("zigimg", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const wallpaper_embed_mod = b.createModule(.{
        .root_source_file = b.path("tools/wallpaper_embed.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    wallpaper_embed_mod.addImport("zigimg", zigimg_dep.module("zigimg"));
    const wallpaper_embed_exe = b.addExecutable(.{
        .name = "wallpaper_embed",
        .root_module = wallpaper_embed_mod,
    });
    const run_wallpaper_embed = b.addRunArtifact(wallpaper_embed_exe);
    run_wallpaper_embed.setCwd(b.path("."));
    const wallpaper_gen_dir = run_wallpaper_embed.addOutputDirectoryArg("wallpaper_gen");
    for (wallpaper_png_inputs) |rel| {
        run_wallpaper_embed.addFileInput(b.path(rel));
    }
    const wallpaper_manifest_lp = wallpaper_gen_dir.path(b, "wallpaper_embed_manifest.zig");
    const wallpaper_data_mod = b.createModule(.{
        .root_source_file = wallpaper_manifest_lp,
        .target = target,
        .optimize = kernel_optimize,
    });

    const desktop_default = b.option(
        []const u8,
        "default_desktop",
        "Default desktop when cmdline omits desktop= (same as Makefile DESKTOP)",
    ) orelse "aero";

    const conf_fb = tryReadPreferredFbFromBuildConf(b);
    const sync_fb = readPreferredFbFromSyncArtifact(b);
    const fb_fallback: PreferredFbDims = .{ .w = 1920, .h = 1080 };
    const zbm_fb_w = b.option(
        u32,
        "zbm_preferred_fb_width",
        "Override ZBM/ramfb width; else build.conf RESOLUTION, else build/tmp/kernel_pref_fb_wh.txt (make sync), else 1920",
    ) orelse if (conf_fb) |c| c.w else if (sync_fb) |s| s.w else fb_fallback.w;
    const zbm_fb_h = b.option(
        u32,
        "zbm_preferred_fb_height",
        "Override ZBM/ramfb height; else build.conf RESOLUTION, else sync artifact, else 1080",
    ) orelse if (conf_fb) |c| c.h else if (sync_fb) |s| s.h else fb_fallback.h;

    const phys_track_gb_raw = b.option(
        u32,
        "phys_track_gb",
        "Kernel frame bitmap span in GiB: 8, 16, 32, or 64 (default 8). Use 16/32/64 for large RAM (e.g. Win7 Ultimate-class); increases kernel BSS and any host test that stack-allocates FrameAllocator.",
    ) orelse 8;
    const phys_track_gb: u32 = switch (phys_track_gb_raw) {
        8, 16, 32, 64 => phys_track_gb_raw,
        else => blk: {
            std.log.err("Invalid -Dphys_track_gb={d}; allowed 8, 16, 32, 64 — using 8", .{phys_track_gb_raw});
            break :blk 8;
        },
    };

    const max_scheduler_threads_raw = b.option(
        u16,
        "max_scheduler_threads",
        "Kernel scheduler thread table slots (clamped 8..256; default 64)",
    ) orelse 64;
    const max_scheduler_threads: u16 = switch (max_scheduler_threads_raw) {
        8...256 => max_scheduler_threads_raw,
        else => blk: {
            std.log.err("Invalid -Dmax_scheduler_threads={d}; allowed 8..256 — using 64", .{max_scheduler_threads_raw});
            break :blk 64;
        },
    };

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "debug", debug_mode);
    build_opts.addOption(bool, "mouse_debug", mouse_debug_opt);
    build_opts.addOption(bool, "agent_ndjson", agent_ndjson_opt);
    build_opts.addOption(bool, "desktop_bisect", desktop_bisect_opt);
    build_opts.addOption(bool, "desktop_full", desktop_full_opt);
    build_opts.addOption(bool, "desktop_shell_no_caption_partial", desktop_shell_no_caption_partial_opt);
    build_opts.addOption(bool, "desktop_bisect_force_full_present", desktop_bisect_force_full_present_opt);
    build_opts.addOption(bool, "desktop_bisect_disable_cursor_move_only", desktop_bisect_disable_cursor_move_only_opt);
    build_opts.addOption(bool, "dwm_blur_stats", dwm_blur_stats_opt);
    build_opts.addOption(bool, "enable_idt", enable_idt_opt);
    build_opts.addOption(bool, "lapic_periodic_tick", lapic_periodic_tick_opt);
    build_opts.addOption(bool, "smp_tlb_ipi", smp_tlb_ipi_opt);
    build_opts.addOption(bool, "amd_igpu", amd_igpu_opt);
    build_opts.addOption(bool, "amd_igpu_defer_probe", amd_igpu_defer_probe_opt);
    build_opts.addOption(bool, "amd_kms_experimental", amd_kms_experimental_opt);
    build_opts.addOption(bool, "intel_igpu", intel_igpu_opt);
    build_opts.addOption(bool, "intel_igpu_defer_probe", intel_igpu_defer_probe_opt);
    build_opts.addOption(bool, "intel_kms_experimental", intel_kms_experimental_opt);
    build_opts.addOption(bool, "nvidia_gpu", nvidia_gpu_opt);
    build_opts.addOption(bool, "nvidia_gpu_defer_probe", nvidia_gpu_defer_probe_opt);
    build_opts.addOption(bool, "nvidia_kms_experimental", nvidia_kms_experimental_opt);
    build_opts.addOption(bool, "nvidia_hdmi_sync", nvidia_hdmi_sync_opt);
    build_opts.addOption(bool, "loongson_igpu", loongson_igpu_opt);
    build_opts.addOption(bool, "loongson_igpu_defer_probe", loongson_igpu_defer_probe_opt);
    build_opts.addOption(bool, "loongson_kms_experimental", loongson_kms_experimental_opt);
    build_opts.addOption(bool, "desktop_idle_spin", desktop_idle_spin_opt);
    build_opts.addOption(bool, "aero_blur_light", aero_blur_light_opt);
    build_opts.addOption(bool, "ps2_mouse_with_virtio", ps2_mouse_with_virtio_opt);
    build_opts.addOption(bool, "force_gop_present", force_gop_present_opt);
    build_opts.addOption(bool, "usb_xhci", usb_xhci_opt);
    build_opts.addOption(bool, "usb_ehci", usb_ehci_opt);
    build_opts.addOption([]const u8, "default_desktop", desktop_default);
    // 与 ZBM `zbm_preferred_fb_*` 同源：ramfb / 诊断与 `build.conf` RESOLUTION 对齐（LoongArch 等 GOP 回退路径）。
    build_opts.addOption(u32, "kernel_preferred_fb_width", zbm_fb_w);
    build_opts.addOption(u32, "kernel_preferred_fb_height", zbm_fb_h);
    build_opts.addOption(u32, "phys_track_gb", phys_track_gb);
    build_opts.addOption(u16, "max_scheduler_threads", max_scheduler_threads);
    build_opts.addOption(u32, "get_message_yield_spins", get_message_yield_spins);

    const code_model: std.builtin.CodeModel = switch (cpu_arch) {
        .x86_64 => .kernel,
        .aarch64 => .small,
        .riscv64 => .medium,
        // LoongArch 内核 VA/恒等与 Large 代码模型易触发 ±2GiB PCREL 溢出；与 RISC-V 一致用 medium。
        .loongarch64 => .medium,
        // MIPS64EL：kseg0 内核地址 + N64 ABI 全局数据需 medium code model，避免 $gp-relative 溢出。
        .mips64el => .medium,
        else => .default,
    };

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = kernel_optimize,
        .link_libc = false,
        .code_model = code_model,
        .pic = false,
        .red_zone = if (cpu_arch == .x86_64) false else null,
        .strip = false,
    });
    root_mod.addOptions("build_options", build_opts);
    root_mod.addImport("wallpaper_data", wallpaper_data_mod);

    const config_defaults_mod = b.createModule(.{
        .root_source_file = b.path("src/config/defaults.zig"),
        .target = target,
        .optimize = kernel_optimize,
    });
    root_mod.addImport("config_defaults", config_defaults_mod);

    const nt61_aero_defaults_mod = b.createModule(.{
        .root_source_file = b.path("src/config/nt61_aero_defaults.zig"),
        .target = target,
        .optimize = kernel_optimize,
    });
    root_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_mod);

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = root_mod,
    });
    kernel.step.dependOn(&run_wallpaper_embed.step);

    const run_aero_sounds = b.addSystemCommand(&.{
        "python3",
        "tools/soundgen/generate_aero_sounds.py",
    });
    run_aero_sounds.setCwd(b.path("."));
    run_aero_sounds.has_side_effects = true;
    const aero_sounds_step = b.step("aero-sounds", "Regenerate Aero theme WAVs under resources/sounds (requires ffmpeg + python3)");
    aero_sounds_step.dependOn(&run_aero_sounds.step);

    addAeroShellIconsDllStep(b, aero_skip_ico_build, aero_windres_exe);
    addAeroShellIconsLaBundleStep(b, aero_skip_ico_build);
    addAeroLoongArchWindowsPeProbeStep(b);

    kernel.entry = .{ .symbol_name = "_start" };
    kernel.link_gc_sections = false;
    kernel.pie = false;
    kernel.link_z_max_page_size = 0x1000;
    // Zig 自托管链接器会覆盖脚本中的起始 VA；显式与 link/x86_64.ld 对齐（UEFI 大内核需避开 16MiB 附近分配失败区）
    if (cpu_arch == .x86_64) {
        kernel.image_base = 0x02000000;
    }

    const linker_script = if (mem.eql(u8, arch_opt, "x86_64"))
        b.path("link/x86_64.ld")
    else if (mem.eql(u8, arch_opt, "aarch64"))
        b.path("link/aarch64.ld")
    else if (mem.eql(u8, arch_opt, "loongarch64"))
        b.path("link/loongarch64.ld")
    else if (mem.eql(u8, arch_opt, "riscv64"))
        b.path("link/riscv64.ld")
    else if (mem.eql(u8, arch_opt, "mips64el"))
        b.path("link/mips64el.ld")
    else
        b.path("link/x86_64.ld");

    kernel.setLinkerScript(linker_script);

    if (mem.eql(u8, arch_opt, "x86_64")) {
        kernel.addAssemblyFile(b.path("src/arch/x86_64/start.s"));
        if (enable_idt_opt) {
            kernel.addAssemblyFile(b.path("src/arch/x86_64/isr_common.s"));
            kernel.addAssemblyFile(b.path("src/arch/x86_64/syscall_lstar.s"));
        }
        kernel.addAssemblyFile(b.path("src/arch/x86_64/kernel_end.s"));
    } else if (mem.eql(u8, arch_opt, "aarch64")) {
        kernel.addAssemblyFile(b.path("src/arch/aarch64/start.S"));
        kernel.addAssemblyFile(b.path("src/arch/aarch64/exception_vector.S"));
        kernel.addAssemblyFile(b.path("src/arch/aarch64/context_switch.S"));
    } else if (mem.eql(u8, arch_opt, "riscv64")) {
        kernel.addAssemblyFile(b.path("src/arch/riscv64/start.S"));
        kernel.addAssemblyFile(b.path("src/arch/riscv64/trap.S"));
        kernel.addAssemblyFile(b.path("src/arch/riscv64/context_switch.S"));
    } else if (mem.eql(u8, arch_opt, "loongarch64")) {
        kernel.addAssemblyFile(b.path("src/arch/loongarch64/crt0.S"));
        kernel.addAssemblyFile(b.path("src/arch/loongarch64/exc_vec.S"));
        kernel.addAssemblyFile(b.path("src/arch/loongarch64/context_switch.S"));
    } else if (mem.eql(u8, arch_opt, "mips64el")) {
        kernel.addAssemblyFile(b.path("src/arch/mips64el/start.S"));
        kernel.addAssemblyFile(b.path("src/arch/mips64el/exceptions.S"));
        kernel.addAssemblyFile(b.path("src/arch/mips64el/context_switch.S"));
    }

    b.installArtifact(kernel);

    const step = b.step("kernel", "Build the kernel ELF");
    step.dependOn(&kernel.step);

    const heap_test_mod = b.createModule(.{
        .root_source_file = b.path("src/mm/heap.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const heap_tests = b.addTest(.{
        .root_module = heap_test_mod,
        .name = "heap",
    });
    const run_heap_tests = b.addRunArtifact(heap_tests);

    const pool_test_mod = b.createModule(.{
        .root_source_file = b.path("src/mm/pool.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const pool_tests = b.addTest(.{
        .root_module = pool_test_mod,
        .name = "pool",
    });
    const run_pool_tests = b.addRunArtifact(pool_tests);

    const buddy_test_mod = b.createModule(.{
        .root_source_file = b.path("src/mm/buddy.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const buddy_tests = b.addTest(.{
        .root_module = buddy_test_mod,
        .name = "buddy",
    });
    const run_buddy_tests = b.addRunArtifact(buddy_tests);

    const slab_test_mod = b.createModule(.{
        .root_source_file = b.path("src/mm/slab.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const slab_tests = b.addTest(.{
        .root_module = slab_test_mod,
        .name = "slab",
    });
    const run_slab_tests = b.addRunArtifact(slab_tests);

    const vm_nt_protect_pte_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/vm_nt_protect_pte_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const vm_nt_protect_pte_tests = b.addTest(.{
        .root_module = vm_nt_protect_pte_host_mod,
        .name = "vm_nt_protect_pte_host",
    });
    const run_vm_nt_protect_pte_tests = b.addRunArtifact(vm_nt_protect_pte_tests);

    const ssdt_test_mod = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/ssdt_nt61.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const ssdt_tests = b.addTest(.{
        .root_module = ssdt_test_mod,
        .name = "ssdt",
    });
    const run_ssdt_tests = b.addRunArtifact(ssdt_tests);

    const ntdll_syscall_stub_mod = b.createModule(.{
        .root_source_file = b.path("src/sdk/ntdll_syscall_win64.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const ssdt_stub_parity_mod = b.createModule(.{
        .root_source_file = b.path("tests/ssdt_stub_parity.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "ssdt", .module = ssdt_test_mod },
            .{ .name = "stub", .module = ntdll_syscall_stub_mod },
        },
    });
    const ssdt_stub_parity_tests = b.addTest(.{
        .root_module = ssdt_stub_parity_mod,
        .name = "ssdt_stub_parity",
    });
    const run_ssdt_stub_parity_tests = b.addRunArtifact(ssdt_stub_parity_tests);

    const se_token_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/se_token.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const se_token_tests = b.addTest(.{
        .root_module = se_token_host_mod,
        .name = "se_token",
    });
    const run_se_token_tests = b.addRunArtifact(se_token_tests);

    const lpc_cross_pid_queue_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/lpc_cross_pid_queue_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const lpc_cross_pid_queue_tests = b.addTest(.{
        .root_module = lpc_cross_pid_queue_host_mod,
        .name = "lpc_cross_pid_queue_host",
    });
    const run_lpc_cross_pid_queue_tests = b.addRunArtifact(lpc_cross_pid_queue_tests);

    const lpc_two_pid_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/lpc_two_pid_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const lpc_two_pid_host_tests = b.addTest(.{
        .root_module = lpc_two_pid_host_mod,
        .name = "lpc_two_pid_host",
    });
    const run_lpc_two_pid_host_tests = b.addRunArtifact(lpc_two_pid_host_tests);

    const lpc_bad_pointer_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/lpc_bad_pointer_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const lpc_bad_pointer_host_tests = b.addTest(.{
        .root_module = lpc_bad_pointer_host_mod,
        .name = "lpc_bad_pointer_host",
    });
    const run_lpc_bad_pointer_host_tests = b.addRunArtifact(lpc_bad_pointer_host_tests);

    const smp_atomic_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/smp_atomic_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const smp_atomic_tests = b.addTest(.{
        .root_module = smp_atomic_host_mod,
        .name = "smp_atomic_host",
    });
    const run_smp_atomic_tests = b.addRunArtifact(smp_atomic_tests);

    const wow64_types_test_mod = b.createModule(.{
        .root_source_file = b.path("src/subsystems/win32/wow64/types.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const wow64_types_tests = b.addTest(.{
        .root_module = wow64_types_test_mod,
        .name = "wow64_types",
    });
    const run_wow64_types_tests = b.addRunArtifact(wow64_types_tests);

    const nt61_aero_defaults_host_mod = b.createModule(.{
        .root_source_file = b.path("src/config/nt61_aero_defaults.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    const ob_object_test_mod = b.createModule(.{
        .root_source_file = b.path("src/zircon_host_ob_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    ob_object_test_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_host_mod);
    ob_object_test_mod.addOptions("build_options", build_opts);
    const ob_object_tests = b.addTest(.{
        .root_module = ob_object_test_mod,
        .name = "object",
    });
    const run_ob_object_tests = b.addRunArtifact(ob_object_tests);

    const io_irp_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/io_irp_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const io_irp_tests = b.addTest(.{
        .root_module = io_irp_host_mod,
        .name = "io_irp_host",
    });
    const run_io_irp_tests = b.addRunArtifact(io_irp_tests);

    const ecam_layout_test_mod = b.createModule(.{
        .root_source_file = b.path("src/hal/x86_64/ecam_layout.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const ecam_layout_tests = b.addTest(.{
        .root_module = ecam_layout_test_mod,
        .name = "ecam_layout",
    });
    const run_ecam_layout_tests = b.addRunArtifact(ecam_layout_tests);

    const acpi_fadt_pm1a_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/acpi_fadt_pm1a_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const acpi_fadt_pm1a_host_tests = b.addTest(.{
        .root_module = acpi_fadt_pm1a_host_mod,
        .name = "acpi_fadt_pm1a_host",
    });
    const run_acpi_fadt_pm1a_host_tests = b.addRunArtifact(acpi_fadt_pm1a_host_tests);

    const acpi_tables_parse_test_mod = b.createModule(.{
        .root_source_file = b.path("src/hal/x86_64/acpi_tables_parse.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const acpi_tables_parse_tests = b.addTest(.{
        .root_module = acpi_tables_parse_test_mod,
        .name = "acpi_tables_parse_host",
    });
    const run_acpi_tables_parse_tests = b.addRunArtifact(acpi_tables_parse_tests);

    const j_smp_inventory_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/j_smp_inventory_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const j_smp_inventory_host_tests = b.addTest(.{
        .root_module = j_smp_inventory_host_mod,
        .name = "j_smp_inventory_host",
    });
    const run_j_smp_inventory_host_tests = b.addRunArtifact(j_smp_inventory_host_tests);

    const hpet_id_test_mod = b.createModule(.{
        .root_source_file = b.path("src/hal/x86_64/hpet_id.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const hpet_id_tests = b.addTest(.{
        .root_module = hpet_id_test_mod,
        .name = "hpet_id",
    });
    const run_hpet_id_tests = b.addRunArtifact(hpet_id_tests);

    const lpc_portkind_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/lpc_portkind_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const lpc_portkind_tests = b.addTest(.{
        .root_module = lpc_portkind_host_mod,
        .name = "lpc_portkind_host",
    });
    const run_lpc_portkind_tests = b.addRunArtifact(lpc_portkind_tests);

    const minimal_net_test_mod = b.createModule(.{
        .root_source_file = b.path("src/drivers/net/minimal_stack.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const minimal_net_tests = b.addTest(.{
        .root_module = minimal_net_test_mod,
        .name = "minimal_net",
    });
    const run_minimal_net_tests = b.addRunArtifact(minimal_net_tests);

    const mdl_test_mod = b.createModule(.{
        .root_source_file = b.path("src/mm/mdl.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const mdl_tests = b.addTest(.{
        .root_module = mdl_test_mod,
        .name = "mdl_host",
    });
    const run_mdl_tests = b.addRunArtifact(mdl_tests);

    const frame_bitmap_math_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/frame_bitmap_math_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const frame_bitmap_math_tests = b.addTest(.{
        .root_module = frame_bitmap_math_host_mod,
        .name = "frame_bitmap_math_host",
    });
    const run_frame_bitmap_math_tests = b.addRunArtifact(frame_bitmap_math_tests);

    const multiboot2_parse_host_mod = b.createModule(.{
        .root_source_file = b.path("src/boot/multiboot2_parse.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const multiboot2_parse_host_tests = b.addTest(.{
        .root_module = multiboot2_parse_host_mod,
        .name = "multiboot2_parse_host",
    });
    const run_multiboot2_parse_host_tests = b.addRunArtifact(multiboot2_parse_host_tests);

    const ke_irql_host_mod = b.createModule(.{
        .root_source_file = b.path("src/ke/irql.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const ke_irql_host_tests = b.addTest(.{
        .root_module = ke_irql_host_mod,
        .name = "ke_irql_host",
    });
    const run_ke_irql_host_tests = b.addRunArtifact(ke_irql_host_tests);

    const paging_x86_host_mod = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/paging.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const paging_x86_host_tests = b.addTest(.{
        .root_module = paging_x86_host_mod,
        .name = "paging_x86_64_host",
    });
    const run_paging_x86_host_tests = b.addRunArtifact(paging_x86_host_tests);

    const pci_bind_test_mod = b.createModule(.{
        .root_source_file = b.path("src/drivers/bus/pci_driver_bind.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const pci_bind_tests = b.addTest(.{
        .root_module = pci_bind_test_mod,
        .name = "pci_driver_bind_host",
    });
    const run_pci_bind_tests = b.addRunArtifact(pci_bind_tests);

    const fs_vfs_constants_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/fs_vfs_constants_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const fs_vfs_constants_tests = b.addTest(.{
        .root_module = fs_vfs_constants_host_mod,
        .name = "fs_vfs_constants_host",
    });
    const run_fs_vfs_constants_tests = b.addRunArtifact(fs_vfs_constants_tests);

    const partition_table_host_mod = b.createModule(.{
        .root_source_file = b.path("src/drivers/storage/partition_table.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const partition_table_host_tests = b.addTest(.{
        .root_module = partition_table_host_mod,
        .name = "partition_table_host",
    });
    const run_partition_table_host_tests = b.addRunArtifact(partition_table_host_tests);

    const fs_status_nt_map_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/fs_status_nt_map_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const fs_status_nt_map_tests = b.addTest(.{
        .root_module = fs_status_nt_map_host_mod,
        .name = "fs_status_nt_map_host",
    });
    const run_fs_status_nt_map_tests = b.addRunArtifact(fs_status_nt_map_tests);

    const nt61_backlog_anchors_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61_full_api_backlog_anchors_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "ssdt", .module = ssdt_test_mod },
        },
    });
    const nt61_backlog_anchors_tests = b.addTest(.{
        .root_module = nt61_backlog_anchors_host_mod,
        .name = "nt61_full_api_backlog_anchors_host",
    });
    const run_nt61_backlog_anchors_tests = b.addRunArtifact(nt61_backlog_anchors_tests);

    const sched_policy_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/scheduler_policy_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const sched_policy_tests = b.addTest(.{
        .root_module = sched_policy_host_mod,
        .name = "scheduler_policy_host",
    });
    const run_sched_policy_tests = b.addRunArtifact(sched_policy_tests);

    const mutex_inherit_depth_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/mutex_inherit_depth_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const mutex_inherit_depth_tests = b.addTest(.{
        .root_module = mutex_inherit_depth_host_mod,
        .name = "mutex_inherit_depth_host",
    });
    const run_mutex_inherit_depth_tests = b.addRunArtifact(mutex_inherit_depth_tests);

    const nt61_phase_f_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61_phase_f_scheduler_gap.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const nt61_phase_f_tests = b.addTest(.{
        .root_module = nt61_phase_f_mod,
        .name = "nt61_phase_f_scheduler_gap",
    });
    const run_nt61_phase_f_tests = b.addRunArtifact(nt61_phase_f_tests);

    const gpu_device_host_mod = b.createModule(.{
        .root_source_file = b.path("src/drivers/video/core/gpu_device.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const gpu_device_tests = b.addTest(.{
        .root_module = gpu_device_host_mod,
        .name = "gpu_device_host",
    });
    const run_gpu_device_tests = b.addRunArtifact(gpu_device_tests);

    const virtio_gpu_spec_host_mod = b.createModule(.{
        .root_source_file = b.path("src/drivers/video/virtio/virtio_gpu_spec.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const virtio_gpu_spec_tests = b.addTest(.{
        .root_module = virtio_gpu_spec_host_mod,
        .name = "virtio_gpu_spec_host",
    });
    const run_virtio_gpu_spec_tests = b.addRunArtifact(virtio_gpu_spec_tests);

    const display_flip_journal_host_mod = b.createModule(.{
        .root_source_file = b.path("src/drivers/video/core/display_flip_journal.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const display_flip_journal_tests = b.addTest(.{
        .root_module = display_flip_journal_host_mod,
        .name = "display_flip_journal_host",
    });
    const run_display_flip_journal_tests = b.addRunArtifact(display_flip_journal_tests);

    const teb_nt61_x64_mod = b.createModule(.{
        .root_source_file = b.path("src/sdk/teb_nt61_x64.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const peb_nt61_x64_host_mod = b.createModule(.{
        .root_source_file = b.path("src/sdk/peb_nt61_x64.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const kuser_shared_nt61_mod = b.createModule(.{
        .root_source_file = b.path("src/sdk/kuser_shared_nt61.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const nt61_abi_layout_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61_abi_layout_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "teb", .module = teb_nt61_x64_mod },
            .{ .name = "peb", .module = peb_nt61_x64_host_mod },
            .{ .name = "kuser", .module = kuser_shared_nt61_mod },
        },
    });
    const nt61_abi_layout_tests = b.addTest(.{
        .root_module = nt61_abi_layout_host_mod,
        .name = "nt61_abi_layout_host",
    });
    const run_nt61_abi_layout_tests = b.addRunArtifact(nt61_abi_layout_tests);

    const system_info_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("src/sdk/system_info_nt61.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const system_info_nt61_layout_tests = b.addTest(.{
        .root_module = system_info_nt61_host_mod,
        .name = "system_info_nt61_host",
    });
    const run_system_info_nt61_layout_tests = b.addRunArtifact(system_info_nt61_layout_tests);

    const object_layout_nt61_mod = b.createModule(.{
        .root_source_file = b.path("sdk/object_layout_nt61.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const object_layout_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/object_layout_nt61_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "object_layout_nt61", .module = object_layout_nt61_mod },
            .{ .name = "teb", .module = teb_nt61_x64_mod },
        },
    });
    const object_layout_nt61_tests = b.addTest(.{
        .root_module = object_layout_nt61_host_mod,
        .name = "object_layout_nt61_host",
    });
    const run_object_layout_nt61_tests = b.addRunArtifact(object_layout_nt61_tests);

    const seh_pdata_min_anchor_mod = b.createModule(.{
        .root_source_file = b.path("src/loader/seh_pdata_min.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const alpc_min_anchor_mod = b.createModule(.{
        .root_source_file = b.path("src/lpc/alpc_min.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const csrss_skeleton_anchor_mod = b.createModule(.{
        .root_source_file = b.path("src/servers/csrss_skeleton.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const stage4_min_anchor_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/stage4_min_anchor_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "seh_pdata_min", .module = seh_pdata_min_anchor_mod },
            .{ .name = "alpc_min", .module = alpc_min_anchor_mod },
            .{ .name = "csrss_skeleton", .module = csrss_skeleton_anchor_mod },
        },
    });
    const stage4_min_anchor_tests = b.addTest(.{
        .root_module = stage4_min_anchor_host_mod,
        .name = "stage4_min_anchor_host",
    });
    const run_stage4_min_anchor_tests = b.addRunArtifact(stage4_min_anchor_tests);

    const sdk_nt61_syscall_path_mod = b.createModule(.{
        .root_source_file = b.path("sdk/nt61_syscall_numbers_x64.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const syscall_numbers_lock_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("src/syscall_numbers_lock_nt61_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "sdk_nt61_syscall_path", .module = sdk_nt61_syscall_path_mod },
        },
    });
    const syscall_numbers_lock_nt61_tests = b.addTest(.{
        .root_module = syscall_numbers_lock_nt61_host_mod,
        .name = "syscall_numbers_lock_nt61_host",
    });
    const run_syscall_numbers_lock_nt61_tests = b.addRunArtifact(syscall_numbers_lock_nt61_tests);

    const wait_user_apc_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("src/wait_user_apc_nt61_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    wait_user_apc_nt61_host_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_host_mod);
    wait_user_apc_nt61_host_mod.addOptions("build_options", build_opts);
    const wait_user_apc_nt61_tests = b.addTest(.{
        .root_module = wait_user_apc_nt61_host_mod,
        .name = "wait_user_apc_nt61_host",
    });
    const run_wait_user_apc_nt61_tests = b.addRunArtifact(wait_user_apc_nt61_tests);

    const nt61_layouts_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/layouts.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const nt61_layouts_tests = b.addTest(.{
        .root_module = nt61_layouts_host_mod,
        .name = "nt61_layouts_host",
    });
    const run_nt61_layouts_tests = b.addRunArtifact(nt61_layouts_tests);

    const pe64_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("sdk/pe64_nt61.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const pe64_nt61_tests = b.addTest(.{
        .root_module = pe64_nt61_host_mod,
        .name = "pe64_nt61_host",
    });
    const run_pe64_nt61_tests = b.addRunArtifact(pe64_nt61_tests);

    const win32k_host_mod = b.createModule(.{
        .root_source_file = b.path("src/subsystems/win32k/mod.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const win32k_tests = b.addTest(.{
        .root_module = win32k_host_mod,
        .name = "win32k_host",
    });
    const run_win32k_tests = b.addRunArtifact(win32k_tests);

    const msg_pm_semantics_host_mod = b.createModule(.{
        .root_source_file = b.path("src/subsystems/win32/msg_pm_semantics.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const msg_pm_semantics_tests = b.addTest(.{
        .root_module = msg_pm_semantics_host_mod,
        .name = "msg_pm_semantics_host",
    });
    const run_msg_pm_semantics_tests = b.addRunArtifact(msg_pm_semantics_tests);

    const gdi_rop_contract_host_mod = b.createModule(.{
        .root_source_file = b.path("src/subsystems/win32/gdi_rop_contract.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const gdi_rop_contract_tests = b.addTest(.{
        .root_module = gdi_rop_contract_host_mod,
        .name = "gdi_rop_contract_host",
    });
    const run_gdi_rop_contract_tests = b.addRunArtifact(gdi_rop_contract_tests);

    const hid_boot_report_host_mod = b.createModule(.{
        .root_source_file = b.path("src/drivers/usb/hid_boot_report.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const hid_boot_report_tests = b.addTest(.{
        .root_module = hid_boot_report_host_mod,
        .name = "hid_boot_report_host",
    });
    const run_hid_boot_report_tests = b.addRunArtifact(hid_boot_report_tests);

    const dwm_surface_spec_host_mod = b.createModule(.{
        .root_source_file = b.path("src/config/dwm_surface_spec.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const dwm_surface_spec_tests = b.addTest(.{
        .root_module = dwm_surface_spec_host_mod,
        .name = "dwm_surface_spec_host",
    });
    const run_dwm_surface_spec_tests = b.addRunArtifact(dwm_surface_spec_tests);

    const aero_flag_mapping_host_mod = b.createModule(.{
        .root_source_file = b.path("src/config/aero_flag_mapping.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const aero_flag_mapping_tests = b.addTest(.{
        .root_module = aero_flag_mapping_host_mod,
        .name = "aero_flag_mapping_host",
    });
    const run_aero_flag_mapping_tests = b.addRunArtifact(aero_flag_mapping_tests);

    const nt61_aero_defaults_tests = b.addTest(.{
        .root_module = nt61_aero_defaults_host_mod,
        .name = "nt61_aero_defaults_host",
    });
    const run_nt61_aero_defaults_tests = b.addRunArtifact(nt61_aero_defaults_tests);

    const csr_lpc_policy_host_mod = b.createModule(.{
        .root_source_file = b.path("src/subsystems/win32/csr_lpc_policy.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const csr_lpc_policy_tests = b.addTest(.{
        .root_module = csr_lpc_policy_host_mod,
        .name = "csr_lpc_policy_host",
    });
    const run_csr_lpc_policy_tests = b.addRunArtifact(csr_lpc_policy_tests);

    const nt61_dual_track_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/nt61_dual_track_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "nt61_aero_defaults", .module = nt61_aero_defaults_host_mod },
            .{ .name = "aero_flag_mapping", .module = aero_flag_mapping_host_mod },
            .{ .name = "csr_lpc_policy", .module = csr_lpc_policy_host_mod },
        },
    });
    const nt61_dual_track_tests = b.addTest(.{
        .root_module = nt61_dual_track_host_mod,
        .name = "nt61_dual_track_host",
    });
    const run_nt61_dual_track_tests = b.addRunArtifact(nt61_dual_track_tests);

    const color_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("src/config/color_nt61.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const color_nt61_tests = b.addTest(.{
        .root_module = color_nt61_host_mod,
        .name = "color_nt61_host",
    });
    const run_color_nt61_tests = b.addRunArtifact(color_nt61_tests);

    const dwm_config_registry_sync_host_mod = b.createModule(.{
        .root_source_file = b.path("src/config/dwm_config_registry_sync.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const dwm_config_registry_sync_tests = b.addTest(.{
        .root_module = dwm_config_registry_sync_host_mod,
        .name = "dwm_config_registry_sync_host",
    });
    const run_dwm_config_registry_sync_tests = b.addRunArtifact(dwm_config_registry_sync_tests);

    const dwm_blur_budget_host_mod = b.createModule(.{
        .root_source_file = b.path("src/config/dwm_blur_budget.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const dwm_blur_budget_tests = b.addTest(.{
        .root_module = dwm_blur_budget_host_mod,
        .name = "dwm_blur_budget_host",
    });
    const run_dwm_blur_budget_tests = b.addRunArtifact(dwm_blur_budget_tests);

    const compositor_sync_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("src/config/compositor_sync_nt61.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const compositor_sync_nt61_tests = b.addTest(.{
        .root_module = compositor_sync_nt61_host_mod,
        .name = "compositor_sync_nt61_host",
    });
    const run_compositor_sync_nt61_tests = b.addRunArtifact(compositor_sync_nt61_tests);

    const dwm_nt61_api_contract_host_mod = b.createModule(.{
        .root_source_file = b.path("src/config/dwm_nt61_api_contract.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const dwm_nt61_api_contract_tests = b.addTest(.{
        .root_module = dwm_nt61_api_contract_host_mod,
        .name = "dwm_nt61_api_contract_host",
    });
    const run_dwm_nt61_api_contract_tests = b.addRunArtifact(dwm_nt61_api_contract_tests);

    const dwm_nt61_abi_inventory_host_mod = b.createModule(.{
        .root_source_file = b.path("src/config/dwm_nt61_abi_inventory.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const dwm_nt61_abi_inventory_tests = b.addTest(.{
        .root_module = dwm_nt61_abi_inventory_host_mod,
        .name = "dwm_nt61_abi_inventory_host",
    });
    const run_dwm_nt61_abi_inventory_tests = b.addRunArtifact(dwm_nt61_abi_inventory_tests);

    const dwmapi_wow64_host_mod = b.createModule(.{
        .root_source_file = b.path("src/subsystems/win32/dwmapi_wow64.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "dwm_nt61_api_contract", .module = dwm_nt61_api_contract_host_mod },
        },
    });
    const dwmapi_wow64_tests = b.addTest(.{
        .root_module = dwmapi_wow64_host_mod,
        .name = "dwmapi_wow64_host",
    });
    const run_dwmapi_wow64_tests = b.addRunArtifact(dwmapi_wow64_tests);

    const ntfs_hive_minimum_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/ntfs_hive_minimum_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const ntfs_hive_minimum_tests = b.addTest(.{
        .root_module = ntfs_hive_minimum_host_mod,
        .name = "ntfs_hive_minimum_host",
    });
    const run_ntfs_hive_minimum_tests = b.addRunArtifact(ntfs_hive_minimum_tests);

    const win32k_api_semantics_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/win32k_api_semantics_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "msg_pm_semantics", .module = msg_pm_semantics_host_mod },
            .{ .name = "csr_lpc_policy", .module = csr_lpc_policy_host_mod },
            .{ .name = "gdi_rop_contract", .module = gdi_rop_contract_host_mod },
            .{ .name = "dwm_nt61_api_contract", .module = dwm_nt61_api_contract_host_mod },
        },
    });
    const win32k_api_semantics_tests = b.addTest(.{
        .root_module = win32k_api_semantics_host_mod,
        .name = "win32k_api_semantics_host",
    });
    const run_win32k_api_semantics_tests = b.addRunArtifact(win32k_api_semantics_tests);

    const dwm_messages_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/dwm_messages_nt61.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "dwm_nt61_api_contract", .module = dwm_nt61_api_contract_host_mod },
            .{ .name = "csr_lpc_policy", .module = csr_lpc_policy_host_mod },
        },
    });
    const dwm_messages_nt61_tests = b.addTest(.{
        .root_module = dwm_messages_nt61_host_mod,
        .name = "dwm_messages_nt61_host",
    });
    const run_dwm_messages_nt61_tests = b.addRunArtifact(dwm_messages_nt61_tests);

    const dwm_zorder_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/dwm_zorder_nt61_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const dwm_zorder_nt61_tests = b.addTest(.{
        .root_module = dwm_zorder_nt61_host_mod,
        .name = "dwm_zorder_nt61_host",
    });
    const run_dwm_zorder_nt61_tests = b.addRunArtifact(dwm_zorder_nt61_tests);

    const multimon_dpi_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/multimon_dpi_nt61_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const multimon_dpi_nt61_tests = b.addTest(.{
        .root_module = multimon_dpi_nt61_host_mod,
        .name = "multimon_dpi_nt61_host",
    });
    const run_multimon_dpi_nt61_tests = b.addRunArtifact(multimon_dpi_nt61_tests);

    const display_set_mode_ioctl_layout_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/display_set_mode_ioctl_layout_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const display_set_mode_ioctl_layout_tests = b.addTest(.{
        .root_module = display_set_mode_ioctl_layout_host_mod,
        .name = "display_set_mode_ioctl_layout_host",
    });
    const run_display_set_mode_ioctl_layout_tests = b.addRunArtifact(display_set_mode_ioctl_layout_tests);

    const taskbar_peek_hit_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/taskbar_peek_hit_nt61_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const taskbar_peek_hit_nt61_tests = b.addTest(.{
        .root_module = taskbar_peek_hit_nt61_host_mod,
        .name = "taskbar_peek_hit_nt61_host",
    });
    const run_taskbar_peek_hit_nt61_tests = b.addRunArtifact(taskbar_peek_hit_nt61_tests);

    const startmenu_paint_hint_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/startmenu_paint_hint_nt61_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const startmenu_paint_hint_nt61_tests = b.addTest(.{
        .root_module = startmenu_paint_hint_nt61_host_mod,
        .name = "startmenu_paint_hint_nt61_host",
    });
    const run_startmenu_paint_hint_nt61_tests = b.addRunArtifact(startmenu_paint_hint_nt61_tests);

    const shell_partial_repaint_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/shell_partial_repaint_nt61_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const shell_partial_repaint_nt61_tests = b.addTest(.{
        .root_module = shell_partial_repaint_nt61_host_mod,
        .name = "shell_partial_repaint_nt61_host",
    });
    const run_shell_partial_repaint_nt61_tests = b.addRunArtifact(shell_partial_repaint_nt61_tests);

    const kernel_stub_audit_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/kernel_stub_audit_anchor_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const kernel_stub_audit_tests = b.addTest(.{
        .root_module = kernel_stub_audit_host_mod,
        .name = "kernel_stub_audit_anchor_host",
    });
    const run_kernel_stub_audit_tests = b.addRunArtifact(kernel_stub_audit_tests);

    const wddm_abstraction_host_mod = b.createModule(.{
        .root_source_file = b.path("src/drivers/video/core/wddm_abstraction.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const dwm_nt61_integration_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/dwm_nt61_integration_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "dwm_config_registry_sync", .module = dwm_config_registry_sync_host_mod },
            .{ .name = "dwm_blur_budget", .module = dwm_blur_budget_host_mod },
            .{ .name = "dwm_nt61_api_contract", .module = dwm_nt61_api_contract_host_mod },
            .{ .name = "compositor_sync_nt61", .module = compositor_sync_nt61_host_mod },
            .{ .name = "wddm_abstraction", .module = wddm_abstraction_host_mod },
            .{ .name = "nt61_aero_defaults", .module = nt61_aero_defaults_host_mod },
        },
    });
    const dwm_nt61_integration_tests = b.addTest(.{
        .root_module = dwm_nt61_integration_host_mod,
        .name = "dwm_nt61_integration_host",
    });
    const run_dwm_nt61_integration_tests = b.addRunArtifact(dwm_nt61_integration_tests);

    const registry_zosh1_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/registry_zosh1_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const registry_zosh1_tests = b.addTest(.{
        .root_module = registry_zosh1_host_mod,
        .name = "registry_zosh1_host",
    });
    const run_registry_zosh1_tests = b.addRunArtifact(registry_zosh1_tests);

    const phase_b_exec_host_mod = b.createModule(.{
        .root_source_file = b.path("src/zircon_host_phase_b_exec_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    phase_b_exec_host_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_host_mod);
    phase_b_exec_host_mod.addOptions("build_options", build_opts);
    const phase_b_exec_host_tests = b.addTest(.{
        .root_module = phase_b_exec_host_mod,
        .name = "phase_b_exec_host",
    });
    const run_phase_b_exec_host_tests = b.addRunArtifact(phase_b_exec_host_tests);

    const regf_parse_host_mod = b.createModule(.{
        .root_source_file = b.path("src/registry/regf_parse.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const regf_parse_tests = b.addTest(.{
        .root_module = regf_parse_host_mod,
        .name = "regf_parse_host",
    });
    const run_regf_parse_tests = b.addRunArtifact(regf_parse_tests);

    const wow64_ssdt_x86_mod = b.createModule(.{
        .root_source_file = b.path("src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const wow64_ssdt_x86_tests = b.addTest(.{
        .root_module = wow64_ssdt_x86_mod,
        .name = "wow64_ssdt_x86",
    });
    const run_wow64_ssdt_x86_tests = b.addRunArtifact(wow64_ssdt_x86_tests);

    const wow64_x64_semantic_alias_host_mod = b.createModule(.{
        .root_source_file = b.path("src/wow64_x64_semantic_alias_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const wow64_x64_semantic_alias_tests = b.addTest(.{
        .root_module = wow64_x64_semantic_alias_host_mod,
        .name = "wow64_x64_semantic_alias_host",
    });
    const run_wow64_x64_semantic_alias_tests = b.addRunArtifact(wow64_x64_semantic_alias_tests);

    const wow64_redirect_host_mod = b.createModule(.{
        .root_source_file = b.path("src/subsystems/win32/wow64/redirect.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const wow64_redirect_tests = b.addTest(.{
        .root_module = wow64_redirect_host_mod,
        .name = "wow64_redirect_host",
    });
    const run_wow64_redirect_tests = b.addRunArtifact(wow64_redirect_tests);

    const phase4_host_anchors_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61/phase4_host_anchors.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "ssdt_x86_win7_sp1", .module = wow64_ssdt_x86_mod },
        },
    });
    const phase4_host_anchors_tests = b.addTest(.{
        .root_module = phase4_host_anchors_mod,
        .name = "phase4_host_anchors",
    });
    const run_phase4_host_anchors_tests = b.addRunArtifact(phase4_host_anchors_tests);

    const ssdt_x64_x86_namespace_mod = b.createModule(.{
        .root_source_file = b.path("tests/ssdt_x64_x86_namespace.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "ssdt_x64", .module = ssdt_test_mod },
            .{ .name = "ssdt_x86", .module = wow64_ssdt_x86_mod },
        },
    });
    const ssdt_x64_x86_namespace_tests = b.addTest(.{
        .root_module = ssdt_x64_x86_namespace_mod,
        .name = "ssdt_x64_x86_namespace",
    });
    const run_ssdt_x64_x86_namespace_tests = b.addRunArtifact(ssdt_x64_x86_namespace_tests);

    const lpc_handshake_version_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/lpc_handshake_version_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const lpc_handshake_version_tests = b.addTest(.{
        .root_module = lpc_handshake_version_host_mod,
        .name = "lpc_handshake_version_host",
    });
    const run_lpc_handshake_version_tests = b.addRunArtifact(lpc_handshake_version_tests);

    const nt61_os_version_layout_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/nt61_os_version_layout_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const nt61_os_version_layout_tests = b.addTest(.{
        .root_module = nt61_os_version_layout_host_mod,
        .name = "nt61_os_version_layout_host",
    });
    const run_nt61_os_version_layout_tests = b.addRunArtifact(nt61_os_version_layout_tests);

    const rtl_verify_version_info_host_mod = b.createModule(.{
        .root_source_file = b.path("src/rtl_verify_version_info_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const rtl_verify_version_info_tests = b.addTest(.{
        .root_module = rtl_verify_version_info_host_mod,
        .name = "rtl_verify_version_info_host",
    });
    const run_rtl_verify_version_info_tests = b.addRunArtifact(rtl_verify_version_info_tests);

    const nt61_core_dll_abi_inventory_host_mod = b.createModule(.{
        .root_source_file = b.path("src/config/nt61_core_dll_abi_inventory.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const nt61_core_dll_abi_inventory_tests = b.addTest(.{
        .root_module = nt61_core_dll_abi_inventory_host_mod,
        .name = "nt61_core_dll_abi_inventory_host",
    });
    const run_nt61_core_dll_abi_inventory_tests = b.addRunArtifact(nt61_core_dll_abi_inventory_tests);

    const pe_loader_policy_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/pe_loader_policy_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const pe_loader_policy_tests = b.addTest(.{
        .root_module = pe_loader_policy_host_mod,
        .name = "pe_loader_policy_host",
    });
    const run_pe_loader_policy_tests = b.addRunArtifact(pe_loader_policy_tests);

    const fork_cow_share_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("src/fork_cow_share_nt61_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    fork_cow_share_nt61_host_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_host_mod);
    fork_cow_share_nt61_host_mod.addOptions("build_options", build_opts);
    const fork_cow_share_nt61_tests = b.addTest(.{
        .root_module = fork_cow_share_nt61_host_mod,
        .name = "fork_cow_share_nt61_host",
    });
    const run_fork_cow_share_nt61_tests = b.addRunArtifact(fork_cow_share_nt61_tests);

    const vm_user_va_policy_nt61_host_mod = b.createModule(.{
        .root_source_file = b.path("src/vm_user_va_policy_nt61_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    vm_user_va_policy_nt61_host_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_host_mod);
    vm_user_va_policy_nt61_host_mod.addOptions("build_options", build_opts);
    const vm_user_va_policy_nt61_tests = b.addTest(.{
        .root_module = vm_user_va_policy_nt61_host_mod,
        .name = "vm_user_va_policy_nt61_host",
    });
    const run_vm_user_va_policy_nt61_tests = b.addRunArtifact(vm_user_va_policy_nt61_tests);

    const loongarch_nt61_mm_host_mod = b.createModule(.{
        .root_source_file = b.path("src/loongarch_nt61_mm_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    loongarch_nt61_mm_host_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_host_mod);
    loongarch_nt61_mm_host_mod.addOptions("build_options", build_opts);
    const loongarch_nt61_mm_host_tests = b.addTest(.{
        .root_module = loongarch_nt61_mm_host_mod,
        .name = "loongarch_nt61_mm_host",
    });
    const run_loongarch_nt61_mm_host_tests = b.addRunArtifact(loongarch_nt61_mm_host_tests);

    const mips64el_nt61_mm_host_mod = b.createModule(.{
        .root_source_file = b.path("src/mips64el_nt61_mm_host.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    mips64el_nt61_mm_host_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_host_mod);
    mips64el_nt61_mm_host_mod.addOptions("build_options", build_opts);
    const mips64el_nt61_mm_host_tests = b.addTest(.{
        .root_module = mips64el_nt61_mm_host_mod,
        .name = "mips64el_nt61_mm_host",
    });
    const run_mips64el_nt61_mm_host_tests = b.addRunArtifact(mips64el_nt61_mm_host_tests);

    const test_step = b.step("test", "Run host unit tests (heap, pool, buddy, slab, vm_nt_protect_pte_host, SSDT, ssdt_stub_parity, ssdt_x64_x86_namespace, se/token, smp_atomic_host, wow64_types, object, io_irp_host, ecam_layout, hpet_id, lpc_portkind_host, lpc_handshake_version_host, nt61_os_version_layout_host, nt61_core_dll_abi_inventory_host, pe_loader_policy_host, fork_cow_share_nt61_host, vm_user_va_policy_nt61_host, loongarch_nt61_mm_host, minimal_net, mdl_host, pci_driver_bind_host, fs_vfs_constants_host, fs_status_nt_map_host, nt61_full_api_backlog_anchors_host, scheduler_policy_host, mutex_inherit_depth_host, nt61_phase_f_scheduler_gap, gpu_device_host, virtio_gpu_spec_host, display_flip_journal_host, nt61_abi_layout_host, win32k_host, msg_pm_semantics_host, gdi_rop_contract_host, hid_boot_report_host, dwm_surface_spec_host, aero_flag_mapping_host, nt61_aero_defaults_host, nt61_dual_track_host, color_nt61_host, dwm_config_registry_sync_host, dwm_blur_budget_host, compositor_sync_nt61_host, dwm_nt61_api_contract_host, dwm_nt61_abi_inventory_host, dwmapi_wow64_host, ntfs_hive_minimum_host, win32k_api_semantics_host, csr_lpc_policy_host, dwm_messages_nt61_host, dwm_zorder_nt61_host, multimon_dpi_nt61_host, taskbar_peek_hit_nt61_host, startmenu_paint_hint_nt61_host, kernel_stub_audit_anchor_host, dwm_nt61_integration_host, registry_zosh1_host, wow64_ssdt_x86, wow64_x64_semantic_alias_host, wow64_redirect_host)");
    test_step.dependOn(&run_heap_tests.step);
    test_step.dependOn(&run_pool_tests.step);
    test_step.dependOn(&run_buddy_tests.step);
    test_step.dependOn(&run_slab_tests.step);
    test_step.dependOn(&run_vm_nt_protect_pte_tests.step);
    test_step.dependOn(&run_ssdt_tests.step);
    test_step.dependOn(&run_ssdt_stub_parity_tests.step);
    test_step.dependOn(&run_se_token_tests.step);
    test_step.dependOn(&run_lpc_cross_pid_queue_tests.step);
    test_step.dependOn(&run_lpc_two_pid_host_tests.step);
    test_step.dependOn(&run_lpc_bad_pointer_host_tests.step);
    test_step.dependOn(&run_smp_atomic_tests.step);
    test_step.dependOn(&run_wow64_types_tests.step);
    test_step.dependOn(&run_ob_object_tests.step);
    test_step.dependOn(&run_io_irp_tests.step);
    test_step.dependOn(&run_ecam_layout_tests.step);
    test_step.dependOn(&run_acpi_fadt_pm1a_host_tests.step);
    test_step.dependOn(&run_acpi_tables_parse_tests.step);
    test_step.dependOn(&run_j_smp_inventory_host_tests.step);
    test_step.dependOn(&run_hpet_id_tests.step);
    test_step.dependOn(&run_lpc_portkind_tests.step);
    test_step.dependOn(&run_minimal_net_tests.step);
    test_step.dependOn(&run_mdl_tests.step);
    test_step.dependOn(&run_frame_bitmap_math_tests.step);
    test_step.dependOn(&run_multiboot2_parse_host_tests.step);
    test_step.dependOn(&run_ke_irql_host_tests.step);
    test_step.dependOn(&run_paging_x86_host_tests.step);
    test_step.dependOn(&run_pci_bind_tests.step);
    test_step.dependOn(&run_fs_vfs_constants_tests.step);
    test_step.dependOn(&run_partition_table_host_tests.step);
    test_step.dependOn(&run_fs_status_nt_map_tests.step);
    test_step.dependOn(&run_nt61_backlog_anchors_tests.step);
    test_step.dependOn(&run_sched_policy_tests.step);
    test_step.dependOn(&run_mutex_inherit_depth_tests.step);
    test_step.dependOn(&run_nt61_phase_f_tests.step);
    test_step.dependOn(&run_gpu_device_tests.step);
    test_step.dependOn(&run_virtio_gpu_spec_tests.step);
    test_step.dependOn(&run_display_flip_journal_tests.step);
    test_step.dependOn(&run_nt61_abi_layout_tests.step);
    test_step.dependOn(&run_system_info_nt61_layout_tests.step);
    test_step.dependOn(&run_object_layout_nt61_tests.step);
    test_step.dependOn(&run_stage4_min_anchor_tests.step);
    test_step.dependOn(&run_syscall_numbers_lock_nt61_tests.step);
    test_step.dependOn(&run_wait_user_apc_nt61_tests.step);
    test_step.dependOn(&run_nt61_layouts_tests.step);
    test_step.dependOn(&run_pe64_nt61_tests.step);
    test_step.dependOn(&run_win32k_tests.step);
    test_step.dependOn(&run_msg_pm_semantics_tests.step);
    test_step.dependOn(&run_gdi_rop_contract_tests.step);
    test_step.dependOn(&run_hid_boot_report_tests.step);
    test_step.dependOn(&run_dwm_surface_spec_tests.step);
    test_step.dependOn(&run_aero_flag_mapping_tests.step);
    test_step.dependOn(&run_nt61_aero_defaults_tests.step);
    test_step.dependOn(&run_nt61_dual_track_tests.step);
    test_step.dependOn(&run_color_nt61_tests.step);
    test_step.dependOn(&run_dwm_config_registry_sync_tests.step);
    test_step.dependOn(&run_dwm_blur_budget_tests.step);
    test_step.dependOn(&run_compositor_sync_nt61_tests.step);
    test_step.dependOn(&run_dwm_nt61_api_contract_tests.step);
    test_step.dependOn(&run_dwm_nt61_abi_inventory_tests.step);
    test_step.dependOn(&run_dwmapi_wow64_tests.step);
    test_step.dependOn(&run_ntfs_hive_minimum_tests.step);
    test_step.dependOn(&run_phase4_host_anchors_tests.step);
    test_step.dependOn(&run_win32k_api_semantics_tests.step);
    test_step.dependOn(&run_csr_lpc_policy_tests.step);
    test_step.dependOn(&run_dwm_messages_nt61_tests.step);
    test_step.dependOn(&run_dwm_zorder_nt61_tests.step);
    test_step.dependOn(&run_multimon_dpi_nt61_tests.step);
    test_step.dependOn(&run_display_set_mode_ioctl_layout_tests.step);
    test_step.dependOn(&run_taskbar_peek_hit_nt61_tests.step);
    test_step.dependOn(&run_startmenu_paint_hint_nt61_tests.step);
    test_step.dependOn(&run_shell_partial_repaint_nt61_tests.step);
    test_step.dependOn(&run_kernel_stub_audit_tests.step);
    test_step.dependOn(&run_dwm_nt61_integration_tests.step);
    test_step.dependOn(&run_registry_zosh1_tests.step);
    test_step.dependOn(&run_phase_b_exec_host_tests.step);
    test_step.dependOn(&run_regf_parse_tests.step);
    test_step.dependOn(&run_wow64_ssdt_x86_tests.step);
    test_step.dependOn(&run_wow64_x64_semantic_alias_tests.step);
    test_step.dependOn(&run_wow64_redirect_tests.step);
    test_step.dependOn(&run_ssdt_x64_x86_namespace_tests.step);
    test_step.dependOn(&run_lpc_handshake_version_tests.step);
    test_step.dependOn(&run_nt61_os_version_layout_tests.step);
    test_step.dependOn(&run_rtl_verify_version_info_tests.step);
    test_step.dependOn(&run_nt61_core_dll_abi_inventory_tests.step);
    test_step.dependOn(&run_pe_loader_policy_tests.step);
    test_step.dependOn(&run_fork_cow_share_nt61_tests.step);
    test_step.dependOn(&run_vm_user_va_policy_nt61_tests.step);
    test_step.dependOn(&run_loongarch_nt61_mm_host_tests.step);
    test_step.dependOn(&run_mips64el_nt61_mm_host_tests.step);

    const pwsh_lite_mod = b.createModule(.{
        .root_source_file = b.path("tools/pwsh-lite/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const pwsh_lite_exe = b.addExecutable(.{
        .name = "pwsh-lite",
        .root_module = pwsh_lite_mod,
    });
    const install_pwsh_lite = b.addInstallArtifact(pwsh_lite_exe, .{});
    const pwsh_lite_step = b.step("pwsh-lite", "Install tools/pwsh-lite → zig-out/bin (not Microsoft PowerShell)");
    pwsh_lite_step.dependOn(&install_pwsh_lite.step);
    const pwsh_lite_tests = b.addTest(.{
        .root_module = pwsh_lite_mod,
        .name = "pwsh_lite_host",
    });
    const run_pwsh_lite_tests = b.addRunArtifact(pwsh_lite_tests);
    test_step.dependOn(&run_pwsh_lite_tests.step);

    addMinimalPeNt61Step(b);

    buildUefi(b, cpu_arch, optimize, debug_mode, zbm_fb_w, zbm_fb_h);
    buildZbm(b, cpu_arch, optimize, debug_mode);
    if (cpu_arch == .loongarch64) {
        buildLoongArchZbmEfiObject(b, optimize, desktop_default, debug_mode, zbm_fb_w, zbm_fb_h);
    }
    if (cpu_arch == .riscv64) {
        buildRiscv64ZbmEfiObject(b, optimize, desktop_default, debug_mode, zbm_fb_w, zbm_fb_h);
    }
    if (cpu_arch == .mips64el) {
        buildMips64elZbmEfiObject(b, optimize, desktop_default, debug_mode, zbm_fb_w, zbm_fb_h);
    }
    buildDesktop(b, optimize);
}

/// 可选：交叉编译 **最小 x64 PE**（仅调用 `ExitProcess`）至 `zig-out/bin/zircon_nt61_minimal_pe.exe`；不依赖微软闭源 DLL。
fn addMinimalPeNt61Step(b: *std.Build) void {
    const win_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const minimal_pe_mod = b.createModule(.{
        .root_source_file = b.path("tools/minimal_pe_nt61/minimal_pe.zig"),
        .target = win_target,
        .optimize = .ReleaseSmall,
    });
    const minimal_pe_exe = b.addExecutable(.{
        .name = "zircon_nt61_minimal_pe",
        .root_module = minimal_pe_mod,
    });
    const install_minimal = b.addInstallArtifact(minimal_pe_exe, .{});
    const minimal_pe_step = b.step("minimal-pe-nt61", "Build tiny x64 PE smoke EXE (ExitProcess; repo-owned)");
    minimal_pe_step.dependOn(&install_minimal.step);
}

const desktop_themes = [_]struct { name: []const u8, dir: []const u8, import_name: []const u8 }{
    .{ .name = "aero", .dir = "src/desktop/aero", .import_name = "ZirconOSAero" },
};

fn buildDesktop(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const theme_opt = b.option(
        []const u8,
        "theme",
        "Desktop theme to build (aero)",
    );

    const target = b.standardTargetOptions(.{});

    // 与 `src/desktop/aero/build.zig` 一致：`theme.zig` 依赖单一玻璃默认值源
    const nt61_aero_defaults_desktop_mod = b.createModule(.{
        .root_source_file = b.path("src/config/nt61_aero_defaults.zig"),
        .target = target,
        .optimize = optimize,
    });
    const aero_flag_mapping_desktop_mod = b.createModule(.{
        .root_source_file = b.path("src/config/aero_flag_mapping.zig"),
        .target = target,
        .optimize = optimize,
    });

    const desktop_all_step = b.step("desktop-all", "Build all desktop themes (EXE + DLL)");
    const dll_all_step = b.step("desktop-dll-all", "Build all desktop theme DLLs");

    for (desktop_themes) |entry| {
        const src_path = b.fmt("{s}/src/main.zig", .{entry.dir});
        const root_path = b.fmt("{s}/src/root.zig", .{entry.dir});
        const exe_name = b.fmt("ZirconOSAero-{s}", .{entry.name});

        const theme_mod = b.addModule(entry.import_name, .{
            .root_source_file = b.path(root_path),
            .target = target,
        });
        theme_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_desktop_mod);
        theme_mod.addImport("aero_flag_mapping", aero_flag_mapping_desktop_mod);

        // EXE
        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_path),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport(entry.import_name, theme_mod);
        // main.zig 使用 @import("root.zig")，与库模块分离；theme 等在 exe 模块内解析 nt61_aero_defaults
        exe.root_module.addImport("nt61_aero_defaults", nt61_aero_defaults_desktop_mod);
        exe.root_module.addImport("aero_flag_mapping", aero_flag_mapping_desktop_mod);
        const install_exe = b.addInstallArtifact(exe, .{});

        // Static library (.lib)
        const lib_rm = b.createModule(.{
            .root_source_file = b.path(root_path),
            .target = target,
            .optimize = optimize,
        });
        lib_rm.addImport("nt61_aero_defaults", nt61_aero_defaults_desktop_mod);
        lib_rm.addImport("aero_flag_mapping", aero_flag_mapping_desktop_mod);
        const lib = b.addLibrary(.{
            .name = exe_name,
            .linkage = .static,
            .root_module = lib_rm,
        });
        const install_lib = b.addInstallArtifact(lib, .{});

        // DLL (shared library / PE DLL when targeting Windows)
        const dll_rm = b.createModule(.{
            .root_source_file = b.path(root_path),
            .target = target,
            .optimize = optimize,
        });
        dll_rm.addImport("nt61_aero_defaults", nt61_aero_defaults_desktop_mod);
        dll_rm.addImport("aero_flag_mapping", aero_flag_mapping_desktop_mod);
        const dll = b.addLibrary(.{
            .name = exe_name,
            .linkage = .dynamic,
            .root_module = dll_rm,
        });
        const install_dll = b.addInstallArtifact(dll, .{});

        // Per-theme EXE step
        const theme_step_name = b.fmt("desktop-{s}", .{entry.name});
        const theme_step_desc = b.fmt("Build {s} desktop theme (EXE + LIB + DLL)", .{entry.name});
        const theme_step = b.step(theme_step_name, theme_step_desc);
        theme_step.dependOn(&install_exe.step);
        theme_step.dependOn(&install_lib.step);
        theme_step.dependOn(&install_dll.step);

        // Per-theme DLL-only step
        const dll_step_name = b.fmt("desktop-{s}-dll", .{entry.name});
        const dll_step_desc = b.fmt("Build {s} desktop DLL only", .{entry.name});
        const dll_step = b.step(dll_step_name, dll_step_desc);
        dll_step.dependOn(&install_dll.step);

        desktop_all_step.dependOn(&install_exe.step);
        desktop_all_step.dependOn(&install_lib.step);
        desktop_all_step.dependOn(&install_dll.step);

        dll_all_step.dependOn(&install_dll.step);
    }

    const desktop_step = b.step("desktop", "Build selected desktop theme (use -Dtheme=NAME)");
    if (theme_opt) |selected| {
        for (desktop_themes) |entry| {
            if (mem.eql(u8, selected, entry.name)) {
                const src_path = b.fmt("{s}/src/main.zig", .{entry.dir});
                const root_path = b.fmt("{s}/src/root.zig", .{entry.dir});
                const exe_name = b.fmt("ZirconOSAero-{s}", .{entry.name});

                const theme_mod = b.addModule(b.fmt("{s}-sel", .{entry.import_name}), .{
                    .root_source_file = b.path(root_path),
                    .target = target,
                });
                theme_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_desktop_mod);

                const exe = b.addExecutable(.{
                    .name = exe_name,
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(src_path),
                        .target = target,
                        .optimize = optimize,
                    }),
                });
                exe.root_module.addImport(entry.import_name, theme_mod);
                exe.root_module.addImport("nt61_aero_defaults", nt61_aero_defaults_desktop_mod);
                const install_sel_exe = b.addInstallArtifact(exe, .{});
                desktop_step.dependOn(&install_sel_exe.step);

                const lib_sel_rm = b.createModule(.{
                    .root_source_file = b.path(root_path),
                    .target = target,
                    .optimize = optimize,
                });
                lib_sel_rm.addImport("nt61_aero_defaults", nt61_aero_defaults_desktop_mod);
                const lib = b.addLibrary(.{
                    .name = exe_name,
                    .linkage = .static,
                    .root_module = lib_sel_rm,
                });
                const install_sel_lib = b.addInstallArtifact(lib, .{});
                desktop_step.dependOn(&install_sel_lib.step);

                const dll_sel_rm = b.createModule(.{
                    .root_source_file = b.path(root_path),
                    .target = target,
                    .optimize = optimize,
                });
                dll_sel_rm.addImport("nt61_aero_defaults", nt61_aero_defaults_desktop_mod);
                const dll = b.addLibrary(.{
                    .name = exe_name,
                    .linkage = .dynamic,
                    .root_module = dll_sel_rm,
                });
                const install_sel_dll = b.addInstallArtifact(dll, .{});
                desktop_step.dependOn(&install_sel_dll.step);
                break;
            }
        }
    }

    // Aero theme as x86_64-freestanding static library (no host libc); for future kernel link.
    const fs_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const nt61_fs = b.createModule(.{
        .root_source_file = b.path("src/config/nt61_aero_defaults.zig"),
        .target = fs_target,
        .optimize = optimize,
    });
    const aero = desktop_themes[0];
    const root_fs_path = b.fmt("{s}/src/root.zig", .{aero.dir});
    const lib_fs_rm = b.createModule(.{
        .root_source_file = b.path(root_fs_path),
        .target = fs_target,
        .optimize = optimize,
    });
    lib_fs_rm.addImport("nt61_aero_defaults", nt61_fs);
    const lib_fs = b.addLibrary(.{
        .name = "ZirconOSAero-aero-freestanding",
        .linkage = .static,
        .root_module = lib_fs_rm,
    });
    const install_fs = b.addInstallArtifact(lib_fs, .{});
    const fs_step = b.step(
        "desktop-aero-freestanding",
        "Build Aero theme as x86_64-freestanding static library (kernel linkage path)",
    );
    fs_step.dependOn(&install_fs.step);
}

fn buildZbm(b: *std.Build, cpu_arch: std.Target.Cpu.Arch, optimize: std.builtin.OptimizeMode, debug_mode: bool) void {
    _ = optimize;
    if (cpu_arch != .x86_64) return;

    const zbm_opts = b.addOptions();
    zbm_opts.addOption(bool, "debug", debug_mode);

    // ZBM BIOS bootstrap components are built via run.sh using GNU as + ld
    // since they contain 16-bit real mode code not supported by Zig's backend.
    //
    // The Zig build system handles the ZBM common modules (BCD, disk, menu, loader)
    // which are compiled as freestanding x86_64 objects for use by the kernel.

    const zbm_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // ZBM common library (BCD, disk, menu, loader)
    const zbm_mod = b.createModule(.{
        .root_source_file = b.path("boot/zbm/zbm.zig"),
        .target = zbm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        .code_model = .kernel,
        .pic = false,
        .red_zone = false,
        .strip = false,
    });
    zbm_mod.addOptions("build_options", zbm_opts);

    const zbm_lib = b.addLibrary(.{
        .name = "zbm",
        .linkage = .static,
        .root_module = zbm_mod,
    });

    const install_zbm = b.addInstallArtifact(zbm_lib, .{});
    const zbm_step = b.step("zbm", "Build ZirconOSAero Boot Manager (ZBM) library");
    zbm_step.dependOn(&install_zbm.step);
}

fn buildUefi(
    b: *std.Build,
    cpu_arch: std.Target.Cpu.Arch,
    optimize: std.builtin.OptimizeMode,
    debug_mode: bool,
    zbm_fb_w: u32,
    zbm_fb_h: u32,
) void {
    // LoongArch: use boot/zbm/uefi/main_loongarch64.zig → .o + GNU-EFI link (see buildLoongArchZbmEfiObject).
    // LoongArch UEFI PE/COFF: Zig's linker does not emit it directly (UnsupportedCoffArchitecture).
    if (cpu_arch == .loongarch64) return;

    // RISC-V：Zig 无法直接链接 riscv64-uefi PE（UnsupportedCoffArchitecture），见 zbm-riscv64-efi.sh + buildRiscv64ZbmEfiObject。
    const uefi_supported = switch (cpu_arch) {
        .x86_64, .aarch64 => true,
        else => false,
    };
    if (!uefi_supported) return;

    const uefi_target = b.resolveTargetQuery(.{
        .cpu_arch = cpu_arch,
        .os_tag = .uefi,
        .abi = .none,
    });

    const desktop_opt = b.option([]const u8, "desktop", "Desktop theme for UEFI boot entries") orelse "aero";

    const uefi_opts = b.addOptions();
    uefi_opts.addOption(bool, "debug", debug_mode);
    uefi_opts.addOption([]const u8, "desktop", desktop_opt);
    uefi_opts.addOption(u32, "zbm_preferred_fb_width", zbm_fb_w);
    uefi_opts.addOption(u32, "zbm_preferred_fb_height", zbm_fb_h);

    const uefi_mod = b.createModule(.{
        .root_source_file = b.path("boot/zbm/uefi/main.zig"),
        .target = uefi_target,
        .optimize = optimize,
    });
    uefi_mod.addOptions("build_options", uefi_opts);

    const efi_stem = switch (cpu_arch) {
        .x86_64 => "BOOTX64",
        .aarch64 => "BOOTAA64",
        else => "zbm",
    };

    const uefi_exe = b.addExecutable(.{
        .name = efi_stem,
        .root_module = uefi_mod,
    });

    const install_uefi = b.addInstallArtifact(uefi_exe, .{});

    const uefi_step = b.step("uefi", "Build ZBM UEFI boot application (.efi; x86_64 / aarch64; riscv64 → zbm-riscv64-uefi)");
    uefi_step.dependOn(&install_uefi.step);
}

/// LoongArch64 ZBM: Zig → `zbm_loongarch64.o` (freestanding), then GNU-EFI crt0 + objcopy → `.efi`.
fn buildLoongArchZbmEfiObject(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    desktop_default: []const u8,
    debug_mode: bool,
    zbm_fb_w: u32,
    zbm_fb_h: u32,
) void {
    const la_target = b.resolveTargetQuery(.{
        .cpu_arch = .loongarch64,
        .os_tag = .freestanding,
        .abi = .none,
        // baseline：LA64 整数 + 双精度；LLVM 仍可能为跳转表生成 `ldx.d`，与 QEMU `-cpu la464` TCG 组合时曾 #INE（见 Makefile QEMU_LOONGARCH64_CPU）。
        .cpu_model = .baseline,
    });
    const zbm_opts = b.addOptions();
    zbm_opts.addOption(bool, "debug", debug_mode);
    zbm_opts.addOption([]const u8, "desktop", desktop_default);
    zbm_opts.addOption(u32, "zbm_preferred_fb_width", zbm_fb_w);
    zbm_opts.addOption(u32, "zbm_preferred_fb_height", zbm_fb_h);
    _ = optimize;
    // ZBM 在 Debug 下仍可能为边界检查/`switch` 生成 `ldx.d` 跳转表；QEMU LoongArch TCG 对部分 `ldx` #INE。
    // LoongArch ZBM 单独用 ReleaseSmall，与内核 `-Doptimize` 脱钩（菜单/加载路径行为不变，仅少调试断言）。
    const zbm_mod = b.createModule(.{
        .root_source_file = b.path("boot/zbm/uefi/main_loongarch64.zig"),
        .target = la_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        // 与内核一致：避免大位移/PCREL 与 la464 默认特性组合下出现非法指令或错址（历史「Zig ZBM INE」根因之一）。
        .code_model = .medium,
    });
    zbm_mod.addOptions("build_options", zbm_opts);
    const zbm_obj = b.addObject(.{
        .name = "zbm_loongarch64",
        .root_module = zbm_mod,
    });
    const install_o = b.addInstallFile(zbm_obj.getEmittedBin(), "zbm_loongarch64.o");
    b.getInstallStep().dependOn(&install_o.step);
    const zbm_la_step = b.step("zbm-loongarch-uefi", "LoongArch ZBM: Zig object (link with scripts/build/zbm-loongarch64-efi.sh → .efi)");
    zbm_la_step.dependOn(&install_o.step);
}

/// RISC-V64 ZBM：GNU-EFI 链接（与 LoongArch 相同，crt0 + objcopy → `.efi`）。
fn buildRiscv64ZbmEfiObject(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    desktop_default: []const u8,
    debug_mode: bool,
    zbm_fb_w: u32,
    zbm_fb_h: u32,
) void {
    const rv_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const zbm_opts = b.addOptions();
    zbm_opts.addOption(bool, "debug", debug_mode);
    zbm_opts.addOption([]const u8, "desktop", desktop_default);
    zbm_opts.addOption(u32, "zbm_preferred_fb_width", zbm_fb_w);
    zbm_opts.addOption(u32, "zbm_preferred_fb_height", zbm_fb_h);
    const zbm_mod = b.createModule(.{
        .root_source_file = b.path("boot/zbm/uefi/main_riscv64.zig"),
        .target = rv_target,
        .optimize = optimize,
        .link_libc = false,
    });
    zbm_mod.addOptions("build_options", zbm_opts);
    const zbm_obj = b.addObject(.{
        .name = "zbm_riscv64",
        .root_module = zbm_mod,
    });
    const install_o = b.addInstallFile(zbm_obj.getEmittedBin(), "zbm_riscv64.o");
    b.getInstallStep().dependOn(&install_o.step);
    const zbm_rv_step = b.step("zbm-riscv64-uefi", "RISC-V64 ZBM: Zig object (link with scripts/build/zbm-riscv64-efi.sh → BOOTRISCV64.EFI)");
    zbm_rv_step.dependOn(&install_o.step);
}

/// MIPS64EL ZBM: Zig → `zbm_mips64el.o` (freestanding), then GNU-EFI crt0 + objcopy → `.efi`.
fn buildMips64elZbmEfiObject(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    desktop_default: []const u8,
    debug_mode: bool,
    zbm_fb_w: u32,
    zbm_fb_h: u32,
) void {
    const mips_target = b.resolveTargetQuery(.{
        .cpu_arch = .mips64el,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const zbm_opts = b.addOptions();
    zbm_opts.addOption(bool, "debug", debug_mode);
    zbm_opts.addOption([]const u8, "desktop", desktop_default);
    zbm_opts.addOption(u32, "zbm_preferred_fb_width", zbm_fb_w);
    zbm_opts.addOption(u32, "zbm_preferred_fb_height", zbm_fb_h);
    _ = optimize;
    const zbm_mod = b.createModule(.{
        .root_source_file = b.path("boot/zbm/uefi/main_mips64el.zig"),
        .target = mips_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        .code_model = .medium,
    });
    zbm_mod.addOptions("build_options", zbm_opts);
    const zbm_obj = b.addObject(.{
        .name = "zbm_mips64el",
        .root_module = zbm_mod,
    });
    const install_o = b.addInstallFile(zbm_obj.getEmittedBin(), "zbm_mips64el.o");
    b.getInstallStep().dependOn(&install_o.step);
    const zbm_mips_step = b.step("zbm-mips64el-uefi", "MIPS64EL ZBM: Zig object (link with scripts/build/zbm-mips64el-efi.sh → BOOTMIPS64EL.EFI)");
    zbm_mips_step.dependOn(&install_o.step);
}

/// Host-only: optional ICO regeneration, MinGW `windres`, then `zig cc -target x86_64-windows-gnu -shared` → PE icon DLL.
/// `zig cc -target loongarch64-windows-gnu -shared` still often fails (UnsupportedCoffArchitecture); use `aero-shell-icons-la-bundle` until upstream fixes.
/// ICO basenames under `src/desktop/aero/resources/win32/ico/` (IconId 1..25, PE 101..125). Must stay aligned with
/// `resources/win32/ICON_RESOURCE_IDS.md` and `laShellIconsManifestJsonAlloc` icon rows.
const aero_shell_icon_basenames = [_][]const u8{
    "computer",      "documents", "recycle_bin",      "terminal",    "network",
    "browser",       "settings",  "calculator",       "text_editor", "pictures",
    "music",         "folder",    "control_panel",    "file",        "user",
    "lock",          "shutdown",  "recycle_bin_full", "drive_fixed", "drive_removable",
    "drive_optical", "printer",   "info",             "warning",     "error",
};

/// JSON manifest for the LoongArch64-style bundle (no PE DLL; PE machine 0x6264 is logical only).
fn laShellIconsManifestJsonAlloc(b: *std.Build) []const u8 {
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(b.allocator);
    const w = list.writer(b.allocator);
    w.print(
        \\{{
        \\  "schema_version": 1,
        \\  "virtual_dll": "zircon_shell32_res.dll",
        \\  "binary_form": "ico_bundle",
        \\  "pe_machine": 25188,
        \\  "pe_machine_hex": "0x6264",
        \\  "pe_machine_name": "IMAGE_FILE_MACHINE_LOONGARCH64",
        \\  "note": "ZirconOSAero: Zig cannot emit loongarch64-windows-gnu COFF DLL yet; this tree mirrors %SystemRoot%\\System32 for Windows-for-LoongArch64 host tests.",
        \\  "icons": [
    , .{}) catch @panic("OOM");

    for (aero_shell_icon_basenames, 0..) |base, i| {
        const logical: u8 = @intCast(i + 1);
        const pe_id: u16 = @intCast(100 + logical);
        if (i > 0) w.print(",\n", .{}) catch @panic("OOM");
        w.print(
            "    {{ \"logical_id\": {d}, \"pe_resource_id\": {d}, \"ico\": \"{s}.ico\", \"shell_reference\": \"zircon_shell32_res.dll,-{d}\" }}",
            .{ logical, pe_id, base, pe_id },
        ) catch @panic("OOM");
    }
    w.print(
        \\
        \\
        \\  ]
        \\}}
        \\
    , .{}) catch @panic("OOM");

    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn addAeroLoongArchWindowsPeProbeStep(b: *std.Build) void {
    const probe = b.addSystemCommand(&.{ "bash", "scripts/build/probe-loongarch-windows-gnu-shared.sh", b.graph.zig_exe });
    probe.setCwd(b.path("."));
    probe.stdio = .inherit;
    probe.has_side_effects = true;
    const st = b.step(
        "aero-loongarch-windows-pe-probe",
        "Probe zig cc -target loongarch64-windows-gnu -shared (Tier 2; may fail until Zig/LLVM COFF supports LoongArch)",
    );
    st.dependOn(&probe.step);
}

fn addAeroShellIconsLaBundleStep(b: *std.Build, skip_ico: bool) void {
    const wf = b.addWriteFiles();
    wf.step.name = b.fmt("aero LoongArch shell icon bundle", .{});

    if (!skip_ico) {
        const run_ico = b.addSystemCommand(&.{ "bash", "scripts/build/build-aero-icons.sh" });
        run_ico.setCwd(b.path("."));
        run_ico.has_side_effects = true;
        wf.step.dependOn(&run_ico.step);
    }

    const ico_dir = "src/desktop/aero/resources/win32/ico";
    for (aero_shell_icon_basenames) |base| {
        const src_ico = b.fmt("{s}/{s}.ico", .{ ico_dir, base });
        const dst_ico = b.fmt("{s}.ico", .{base});
        _ = wf.addCopyFile(b.path(src_ico), dst_ico);
    }

    const manifest = laShellIconsManifestJsonAlloc(b);
    defer b.allocator.free(manifest);
    _ = wf.add("zircon_shell32_res.manifest.json", manifest);

    const install_la = b.addInstallDirectory(.{
        .source_dir = wf.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "assets/loongarch64/win/System32",
    });

    const la_step = b.step(
        "aero-shell-icons-la-bundle",
        "ICO + zircon_shell32_res.manifest.json → zig-out/assets/loongarch64/win/System32 (no PE DLL)",
    );
    la_step.dependOn(&install_la.step);
}

fn addAeroShellIconsDllStep(b: *std.Build, skip_ico: bool, windres_exe: []const u8) void {
    const windres_cmd = b.addSystemCommand(&.{ windres_exe, "-i", "zircon_shell32_res.rc", "-o" });
    const rc_o = windres_cmd.addOutputFileArg("zircon_shell32_res.o");
    windres_cmd.setCwd(b.path("src/desktop/aero/resources/win32"));
    windres_cmd.stdio = .inherit;
    windres_cmd.has_side_effects = true;

    if (!skip_ico) {
        const run_ico = b.addSystemCommand(&.{ "bash", "scripts/build/build-aero-icons.sh" });
        run_ico.setCwd(b.path("."));
        run_ico.has_side_effects = true;
        windres_cmd.step.dependOn(&run_ico.step);
    }

    const zig_cc = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-target", "x86_64-windows-gnu", "-shared" });
    zig_cc.addFileArg(rc_o);
    zig_cc.addFileArg(b.path("src/desktop/aero/resources/win32/zircon_shell32_res_stub.c"));
    zig_cc.addArg("-o");
    const dll_out = zig_cc.addOutputFileArg("zircon_shell32_res.dll");
    zig_cc.step.dependOn(&windres_cmd.step);
    zig_cc.stdio = .inherit;
    zig_cc.has_side_effects = true;

    const install_dll = b.addInstallFile(dll_out, "assets/zircon_shell32_res.dll");
    install_dll.step.dependOn(&zig_cc.step);

    const aero_shell_icons_dll_step = b.step("aero-shell-icons-dll", "Build zircon_shell32_res.dll (windres + zig cc -target x86_64-windows-gnu; Win32 RT_ICON)");
    aero_shell_icons_dll_step.dependOn(&install_dll.step);
}
