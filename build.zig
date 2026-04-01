const std = @import("std");
const mem = std.mem;

const PreferredFbDims = struct { w: u32, h: u32 };

/// PNG sources for `tools/wallpaper_embed.zig` (preset order 0..11).
const wallpaper_png_inputs = [_][]const u8{
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_harmony.png",
    "src/desktop/aero/resources/wallpapers/Nature/zircon_default.png",
    "src/desktop/aero/resources/wallpapers/Architecture/zircon_crystal.png",
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_aurora.png",
    "src/desktop/aero/resources/wallpapers/Characters/zircon_characters.png",
    "src/desktop/aero/resources/wallpapers/Nature/zircon_nature.png",
    "src/desktop/aero/resources/wallpapers/Scenes/zircon_scenes.png",
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_landscapes.png",
    "src/desktop/aero/resources/wallpapers/Architecture/zircon_architecture.png",
    "src/desktop/aero/resources/wallpapers/Nature/zircon_ocean.png",
    "src/desktop/aero/resources/wallpapers/Scenes/zircon_nebula.png",
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_landscape.png",
};

/// Parse `RESOLUTION = WxHxdepth` from build.conf text (first match).
fn parseResolutionFromBuildConfText(content: []const u8) ?PreferredFbDims {
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (!std.mem.startsWith(u8, trimmed, "RESOLUTION")) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        var val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (std.mem.indexOfScalar(u8, val, '#')) |hi| {
            val = std.mem.trim(u8, val[0..hi], " \t");
        }
        var parts = std.mem.splitScalar(u8, val, 'x');
        const ws = parts.next() orelse continue;
        const hs = parts.next() orelse continue;
        const w = std.fmt.parseUnsigned(u32, ws, 10) catch continue;
        const h = std.fmt.parseUnsigned(u32, hs, 10) catch continue;
        if (w == 0 or h == 0) continue;
        return .{ .w = w, .h = h };
    }
    return null;
}

/// `make build` / `sync_resolution` 写入 `build/tmp/kernel_pref_fb_wh.txt`（与 ZIRCON_RESOLUTION / build.conf 一致）。
fn readPreferredFbFromSyncArtifact(b: *std.Build) ?PreferredFbDims {
    const path = "build/tmp/kernel_pref_fb_wh.txt";
    const file = b.build_root.handle.openFile(path, .{}) catch return null;
    defer file.close();
    const max_bytes: usize = 128;
    const raw = file.readToEndAlloc(b.allocator, max_bytes) catch return null;
    defer b.allocator.free(raw);
    var iter = std.mem.splitScalar(u8, raw, '\n');
    const wline = std.mem.trim(u8, iter.next() orelse return null, " \t\r");
    const hline = std.mem.trim(u8, iter.next() orelse return null, " \t\r");
    if (wline.len == 0 or hline.len == 0) return null;
    const w = std.fmt.parseUnsigned(u32, wline, 10) catch return null;
    const h = std.fmt.parseUnsigned(u32, hline, 10) catch return null;
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h };
}

/// 仅当 `build.conf` 中存在未注释的 `RESOLUTION = WxHxdepth` 时返回 Some；否则 null（与 sync 脚本语义一致）。
fn tryReadPreferredFbFromBuildConf(b: *std.Build) ?PreferredFbDims {
    const file = b.build_root.handle.openFile("build.conf", .{}) catch return null;
    defer file.close();
    const max_bytes: usize = 65536;
    const raw = file.readToEndAlloc(b.allocator, max_bytes) catch return null;
    defer b.allocator.free(raw);
    return parseResolutionFromBuildConfText(raw);
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

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
    const enable_idt_opt = b.option(bool, "enable_idt", "Enable IDT, timer and syscall (x86_64 only)") orelse true;
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

    const target = b.resolveTargetQuery(.{
        .cpu_arch = cpu_arch,
        .os_tag = .freestanding,
        .abi = .none,
    });

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
        .optimize = optimize,
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

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "debug", debug_mode);
    build_opts.addOption(bool, "mouse_debug", mouse_debug_opt);
    build_opts.addOption(bool, "agent_ndjson", agent_ndjson_opt);
    build_opts.addOption(bool, "desktop_bisect", desktop_bisect_opt);
    build_opts.addOption(bool, "enable_idt", enable_idt_opt);
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
    build_opts.addOption(bool, "usb_xhci", usb_xhci_opt);
    build_opts.addOption(bool, "usb_ehci", usb_ehci_opt);
    build_opts.addOption([]const u8, "default_desktop", desktop_default);
    // 与 ZBM `zbm_preferred_fb_*` 同源：ramfb / 诊断与 `build.conf` RESOLUTION 对齐（LoongArch 等 GOP 回退路径）。
    build_opts.addOption(u32, "kernel_preferred_fb_width", zbm_fb_w);
    build_opts.addOption(u32, "kernel_preferred_fb_height", zbm_fb_h);

    const code_model: std.builtin.CodeModel = switch (cpu_arch) {
        .x86_64 => .kernel,
        .aarch64 => .small,
        .riscv64 => .medium,
        else => .default,
    };

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
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
        .optimize = optimize,
    });
    root_mod.addImport("config_defaults", config_defaults_mod);

    const zircon_aero_defaults_mod = b.createModule(.{
        .root_source_file = b.path("src/config/zircon_aero_defaults.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("zircon_aero_defaults", zircon_aero_defaults_mod);

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
            kernel.addAssemblyFile(b.path("src/arch/x86_64/syscall_entry.s"));
            kernel.addAssemblyFile(b.path("src/arch/x86_64/syscall_lstar.s"));
        }
    } else if (mem.eql(u8, arch_opt, "aarch64")) {
        kernel.addAssemblyFile(b.path("src/arch/aarch64/start.S"));
    } else if (mem.eql(u8, arch_opt, "riscv64")) {
        kernel.addAssemblyFile(b.path("src/arch/riscv64/start.S"));
    } else if (mem.eql(u8, arch_opt, "loongarch64")) {
        kernel.addAssemblyFile(b.path("src/arch/loongarch64/crt0.S"));
        kernel.addAssemblyFile(b.path("src/arch/loongarch64/exc_vec.S"));
    }

    b.installArtifact(kernel);

    const step = b.step("kernel", "Build the kernel ELF");
    step.dependOn(&kernel.step);

    buildUefi(b, cpu_arch, optimize, debug_mode, zbm_fb_w, zbm_fb_h);
    buildZbm(b, cpu_arch, optimize, debug_mode);
    if (cpu_arch == .loongarch64) {
        buildLoongArchZbmEfiObject(b, optimize, desktop_default, debug_mode, zbm_fb_w, zbm_fb_h);
    }
    if (cpu_arch == .riscv64) {
        buildRiscv64ZbmEfiObject(b, optimize, desktop_default, debug_mode, zbm_fb_w, zbm_fb_h);
    }
    buildDesktop(b, optimize);
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
    const zircon_aero_defaults_desktop_mod = b.createModule(.{
        .root_source_file = b.path("src/config/zircon_aero_defaults.zig"),
        .target = target,
        .optimize = optimize,
    });

    const desktop_all_step = b.step("desktop-all", "Build all desktop themes (EXE + DLL)");
    const dll_all_step = b.step("desktop-dll-all", "Build all desktop theme DLLs");

    for (desktop_themes) |entry| {
        const src_path = b.fmt("{s}/src/main.zig", .{entry.dir});
        const root_path = b.fmt("{s}/src/root.zig", .{entry.dir});
        const exe_name = b.fmt("ZirconOS-{s}", .{entry.name});

        const theme_mod = b.addModule(entry.import_name, .{
            .root_source_file = b.path(root_path),
            .target = target,
        });
        theme_mod.addImport("zircon_aero_defaults", zircon_aero_defaults_desktop_mod);

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
        // main.zig 使用 @import("root.zig")，与库模块分离；theme 等在 exe 模块内解析 zircon_aero_defaults
        exe.root_module.addImport("zircon_aero_defaults", zircon_aero_defaults_desktop_mod);
        const install_exe = b.addInstallArtifact(exe, .{});

        // Static library (.lib)
        const lib_rm = b.createModule(.{
            .root_source_file = b.path(root_path),
            .target = target,
            .optimize = optimize,
        });
        lib_rm.addImport("zircon_aero_defaults", zircon_aero_defaults_desktop_mod);
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
        dll_rm.addImport("zircon_aero_defaults", zircon_aero_defaults_desktop_mod);
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
                const exe_name = b.fmt("ZirconOS-{s}", .{entry.name});

                const theme_mod = b.addModule(b.fmt("{s}-sel", .{entry.import_name}), .{
                    .root_source_file = b.path(root_path),
                    .target = target,
                });
                theme_mod.addImport("zircon_aero_defaults", zircon_aero_defaults_desktop_mod);

                const exe = b.addExecutable(.{
                    .name = exe_name,
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(src_path),
                        .target = target,
                        .optimize = optimize,
                    }),
                });
                exe.root_module.addImport(entry.import_name, theme_mod);
                exe.root_module.addImport("zircon_aero_defaults", zircon_aero_defaults_desktop_mod);
                const install_sel_exe = b.addInstallArtifact(exe, .{});
                desktop_step.dependOn(&install_sel_exe.step);

                const lib_sel_rm = b.createModule(.{
                    .root_source_file = b.path(root_path),
                    .target = target,
                    .optimize = optimize,
                });
                lib_sel_rm.addImport("zircon_aero_defaults", zircon_aero_defaults_desktop_mod);
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
                dll_sel_rm.addImport("zircon_aero_defaults", zircon_aero_defaults_desktop_mod);
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
    const zbm_step = b.step("zbm", "Build ZirconOS Boot Manager library");
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
        .cpu_model = .baseline, // 避免 la464 不支持的指令（INE 异常）
    });
    const zbm_opts = b.addOptions();
    zbm_opts.addOption(bool, "debug", debug_mode);
    zbm_opts.addOption([]const u8, "desktop", desktop_default);
    zbm_opts.addOption(u32, "zbm_preferred_fb_width", zbm_fb_w);
    zbm_opts.addOption(u32, "zbm_preferred_fb_height", zbm_fb_h);
    const zbm_mod = b.createModule(.{
        .root_source_file = b.path("boot/zbm/uefi/main_loongarch64.zig"),
        .target = la_target,
        .optimize = optimize,
        .link_libc = false,
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
        .root_source_file = b.path("boot/zbm/uefi/main.zig"),
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
        \\  "note": "ZirconOS: Zig cannot emit loongarch64-windows-gnu COFF DLL yet; this tree mirrors %SystemRoot%\\System32 for Windows-for-LoongArch64 host tests.",
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
