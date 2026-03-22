const std = @import("std");
const mem = std.mem;

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const arch_opt = b.option(
        []const u8,
        "arch",
        "Target architecture (x86_64, loongarch64, aarch64, riscv64, mips64el)",
    ) orelse "x86_64";
    const debug_mode = b.option(bool, "debug", "Enable debug mode (verbose klog, serial output)") orelse false;
    const enable_idt_opt = b.option(bool, "enable_idt", "Enable IDT, timer and syscall (x86_64 only)") orelse true;

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

    const target = b.resolveTargetQuery(.{
        .cpu_arch = cpu_arch,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const desktop_default = b.option(
        []const u8,
        "default_desktop",
        "Default desktop when cmdline omits desktop= (same as Makefile DESKTOP)",
    ) orelse "aero";

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "debug", debug_mode);
    build_opts.addOption(bool, "enable_idt", enable_idt_opt);
    build_opts.addOption([]const u8, "default_desktop", desktop_default);

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

    const config_defaults_mod = b.createModule(.{
        .root_source_file = b.path("src/config/defaults.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("config_defaults", config_defaults_mod);

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = root_mod,
    });

    kernel.entry = .{ .symbol_name = "_start" };
    kernel.link_gc_sections = false;
    kernel.pie = false;
    kernel.link_z_max_page_size = 0x1000;

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
        }
    } else if (mem.eql(u8, arch_opt, "aarch64")) {
        kernel.addAssemblyFile(b.path("src/arch/aarch64/start.S"));
    } else if (mem.eql(u8, arch_opt, "riscv64")) {
        kernel.addAssemblyFile(b.path("src/arch/riscv64/start.S"));
    } else if (mem.eql(u8, arch_opt, "loongarch64")) {
        kernel.addAssemblyFile(b.path("src/arch/loongarch64/crt0.S"));
    }

    b.installArtifact(kernel);

    const step = b.step("kernel", "Build the kernel ELF");
    step.dependOn(&kernel.step);

    buildUefi(b, cpu_arch, optimize, debug_mode);
    buildZbm(b, cpu_arch, optimize, debug_mode);
    if (cpu_arch == .loongarch64) {
        buildLoongArchZbmEfiObject(b, optimize, desktop_default, debug_mode);
    }
    if (cpu_arch == .riscv64) {
        buildRiscv64ZbmEfiObject(b, optimize, desktop_default, debug_mode);
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
        const install_exe = b.addInstallArtifact(exe, .{});

        // Static library (.lib)
        const lib = b.addLibrary(.{
            .name = exe_name,
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path(root_path),
                .target = target,
                .optimize = optimize,
            }),
        });
        const install_lib = b.addInstallArtifact(lib, .{});

        // DLL (shared library / PE DLL when targeting Windows)
        const dll = b.addLibrary(.{
            .name = exe_name,
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path(root_path),
                .target = target,
                .optimize = optimize,
            }),
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

                const exe = b.addExecutable(.{
                    .name = exe_name,
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(src_path),
                        .target = target,
                        .optimize = optimize,
                    }),
                });
                exe.root_module.addImport(entry.import_name, theme_mod);
                const install_sel_exe = b.addInstallArtifact(exe, .{});
                desktop_step.dependOn(&install_sel_exe.step);

                const lib = b.addLibrary(.{
                    .name = exe_name,
                    .linkage = .static,
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(root_path),
                        .target = target,
                        .optimize = optimize,
                    }),
                });
                const install_sel_lib = b.addInstallArtifact(lib, .{});
                desktop_step.dependOn(&install_sel_lib.step);

                const dll = b.addLibrary(.{
                    .name = exe_name,
                    .linkage = .dynamic,
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(root_path),
                        .target = target,
                        .optimize = optimize,
                    }),
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

fn buildUefi(b: *std.Build, cpu_arch: std.Target.Cpu.Arch, optimize: std.builtin.OptimizeMode, debug_mode: bool) void {
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
fn buildLoongArchZbmEfiObject(b: *std.Build, optimize: std.builtin.OptimizeMode, desktop_default: []const u8, debug_mode: bool) void {
    const la_target = b.resolveTargetQuery(.{
        .cpu_arch = .loongarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .baseline, // 避免 la464 不支持的指令（INE 异常）
    });
    const zbm_opts = b.addOptions();
    zbm_opts.addOption(bool, "debug", debug_mode);
    zbm_opts.addOption([]const u8, "desktop", desktop_default);
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
fn buildRiscv64ZbmEfiObject(b: *std.Build, optimize: std.builtin.OptimizeMode, desktop_default: []const u8, debug_mode: bool) void {
    const rv_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const zbm_opts = b.addOptions();
    zbm_opts.addOption(bool, "debug", debug_mode);
    zbm_opts.addOption([]const u8, "desktop", desktop_default);
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
