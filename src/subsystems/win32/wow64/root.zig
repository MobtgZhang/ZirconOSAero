// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/root.zig
// Purpose: WOW64 main entry - dispatches to architecture-specific engines.
// This is an independent clean-room implementation.

const builtin = @import("builtin");
const klog = @import("../../../rtl/klog.zig");
const ntdll = @import("../../../libs/ntdll.zig");
const types = @import("types.zig");

var wow64_initialized: bool = false;
var wow64_init_status: ntdll.NTSTATUS = ntdll.STATUS_SUCCESS;

pub const EngineInfo = struct {
    name: []const u8,
    state: []const u8,
    features: u32,
};

pub const GlobalStats = struct {
    total_translations: u64,
    total_cache_hits: u64,
    total_syscalls: u64,
    total_thunks: u64,
};

var global_stats: GlobalStats = .{
    .total_translations = 0,
    .total_cache_hits = 0,
    .total_syscalls = 0,
    .total_thunks = 0,
};

pub fn initWow64() ntdll.NTSTATUS {
    if (wow64_initialized) return wow64_init_status;

    klog.info("wow64: initializing for architecture: {}", .{builtin.cpu.arch});
    klog.info("wow64: version {}", .{types.WOW64_VERSION});

    const st = switch (builtin.cpu.arch) {
        .loongarch64 => {
            const la64_engine = @import("la64_engine.zig");
            const st = la64_engine.engineInit();
            if (st == ntdll.STATUS_SUCCESS) {
                const stats = la64_engine.getTranslationStats();
                klog.info("wow64(la64): translations={}, hits={}, rate={:.2}", .{
                    stats.total_translations,
                    stats.total_cache_hits,
                    stats.cache_hit_rate,
                });
            }
            return st;
        },
        .aarch64 => {
            const aarch64_engine = @import("aarch64_engine.zig");
            const st = aarch64_engine.engineInit();
            if (st == ntdll.STATUS_SUCCESS) {
                const stats = aarch64_engine.getTranslationStats();
                klog.info("wow64(aarch64): translations={}, hits={}, rate={:.2}", .{
                    stats.total_translations,
                    stats.total_cache_hits,
                    stats.cache_hit_rate,
                });
            }
            return st;
        },
        .riscv64 => {
            const riscv64_engine = @import("riscv64_engine.zig");
            const st = riscv64_engine.engineInit();
            if (st == ntdll.STATUS_SUCCESS) {
                const stats = riscv64_engine.getTranslationStats();
                klog.info("wow64(riscv64): translations={}, hits={}, rate={:.2}", .{
                    stats.total_translations,
                    stats.total_cache_hits,
                    stats.cache_hit_rate,
                });
            }
            return st;
        },
        .mips64el => {
            const mips64_engine = @import("mips64_engine_stub.zig");
            const st = mips64_engine.engineInit();
            if (st == ntdll.STATUS_SUCCESS) {
                const stats = mips64_engine.getTranslationStats();
                klog.info("wow64(mips64el): translations={}, hits={}, rate={:.2}", .{
                    stats.total_translations,
                    stats.total_cache_hits,
                    stats.cache_hit_rate,
                });
            }
            return st;
        },
        else => {
            klog.err("wow64: unsupported architecture: {}", .{builtin.cpu.arch});
            return ntdll.STATUS_NOT_SUPPORTED;
        },
    };

    wow64_init_status = st;
    if (st == ntdll.STATUS_SUCCESS) {
        wow64_initialized = true;
    }
    return st;
}

pub fn dispatchExecution(context: *types.Wow64Process, entry: u64) ntdll.NTSTATUS {
    if (!wow64_initialized) {
        const st = initWow64();
        if (st != ntdll.STATUS_SUCCESS) return st;
    }

    global_stats.total_syscalls += 1;

    return switch (builtin.cpu.arch) {
        .loongarch64 => {
            const la64_engine = @import("la64_engine.zig");
            return la64_engine.translateAndExecute(@truncate(entry), @intFromPtr(context));
        },
        .aarch64 => {
            const aarch64_engine = @import("aarch64_engine.zig");
            return aarch64_engine.translateAndExecute(@truncate(entry), @intFromPtr(context));
        },
        .riscv64 => {
            const riscv64_engine = @import("riscv64_engine.zig");
            return riscv64_engine.translateAndExecute(@truncate(entry), @intFromPtr(context));
        },
        .mips64el => {
            const mips64_engine = @import("mips64_engine_stub.zig");
            return mips64_engine.translateAndExecute(entry, @intFromPtr(context));
        },
        else => ntdll.STATUS_NOT_SUPPORTED,
    };
}

pub fn isEngineAvailable() bool {
    return switch (builtin.cpu.arch) {
        .loongarch64 => @import("la64_engine.zig").isEngineAvailable(),
        .aarch64 => @import("aarch64_engine.zig").isEngineAvailable(),
        .riscv64 => @import("riscv64_engine.zig").isEngineAvailable(),
        .mips64el => @import("mips64_engine_stub.zig").isEngineAvailable(),
        else => false,
    };
}

pub fn getEngineInfo() EngineInfo {
    return switch (builtin.cpu.arch) {
        .loongarch64 => {
            const la64_engine = @import("la64_engine.zig");
            return .{
                .name = "LoongArch64",
                .state = @tagName(la64_engine.EngineState),
                .features = @as(u32, @bitCast(la64_engine.getEngineFeatures())),
            };
        },
        .aarch64 => {
            const aarch64_engine = @import("aarch64_engine.zig");
            return .{
                .name = "ARM64",
                .state = @tagName(aarch64_engine.EngineState),
                .features = @as(u32, @bitCast(aarch64_engine.getEngineFeatures())),
            };
        },
        .riscv64 => {
            const riscv64_engine = @import("riscv64_engine.zig");
            return .{
                .name = "RISC-V64",
                .state = @tagName(riscv64_engine.EngineState),
                .features = @as(u32, @bitCast(riscv64_engine.getEngineFeatures())),
            };
        },
        .mips64el => {
            const mips64_engine = @import("mips64_engine_stub.zig");
            return .{
                .name = "MIPS64EL",
                .state = @tagName(mips64_engine.EngineState),
                .features = @as(u32, @bitCast(mips64_engine.getEngineFeatures())),
            };
        },
        else => .{
            .name = "Unknown",
            .state = "unavailable",
            .features = 0,
        },
    };
}

pub fn getGlobalStats() GlobalStats {
    var stats = global_stats;

    if (builtin.cpu.arch == .loongarch64) {
        const la64_engine = @import("la64_engine.zig");
        const engine_stats = la64_engine.getTranslationStats();
        stats.total_translations = engine_stats.total_translations;
        stats.total_cache_hits = engine_stats.total_cache_hits;
    }

    return stats;
}

pub fn getEngineStats() ?TranslationStatsCombined {
    return switch (builtin.cpu.arch) {
        .loongarch64 => {
            const la64_engine = @import("la64_engine.zig");
            const s = la64_engine.getTranslationStats();
            return .{
                .total_translations = s.total_translations,
                .total_translated_insns = s.total_translated_insns,
                .total_cache_hits = s.total_cache_hits,
                .total_lbt_assists = s.total_lbt_assists,
                .total_page_faults = s.total_page_faults,
                .cache_hit_rate = s.cache_hit_rate,
            };
        },
        .aarch64 => {
            const aarch64_engine = @import("aarch64_engine.zig");
            const s = aarch64_engine.getTranslationStats();
            return .{
                .total_translations = s.total_translations,
                .total_translated_insns = s.total_translated_insns,
                .total_cache_hits = s.total_cache_hits,
                .total_lbt_assists = s.total_eflags_emulations,
                .total_page_faults = s.total_page_faults,
                .cache_hit_rate = s.cache_hit_rate,
            };
        },
        .riscv64 => {
            const riscv64_engine = @import("riscv64_engine.zig");
            const s = riscv64_engine.getTranslationStats();
            return .{
                .total_translations = s.total_translations,
                .total_translated_insns = s.total_translated_insns,
                .total_cache_hits = s.total_cache_hits,
                .total_lbt_assists = 0,
                .total_page_faults = s.total_page_faults,
                .cache_hit_rate = s.cache_hit_rate,
            };
        },
        .mips64el => {
            const mips64_engine = @import("mips64_engine_stub.zig");
            const s = mips64_engine.getTranslationStats();
            return .{
                .total_translations = s.total_translations,
                .total_translated_insns = s.total_translated_insns,
                .total_cache_hits = s.total_cache_hits,
                .total_lbt_assists = s.total_delay_slots,
                .total_page_faults = s.total_page_faults,
                .cache_hit_rate = s.cache_hit_rate,
            };
        },
        else => null,
    };
}

pub const TranslationStatsCombined = struct {
    total_translations: u64,
    total_translated_insns: u64,
    total_cache_hits: u64,
    total_lbt_assists: u64,
    total_page_faults: u64,
    cache_hit_rate: f64,
};

pub fn invalidateAllCaches() void {
    switch (builtin.cpu.arch) {
        .loongarch64 => {
            const la64_engine = @import("la64_engine.zig");
            la64_engine.invalidateAllTranslations();
        },
        .aarch64 => {
            const aarch64_engine = @import("aarch64_engine.zig");
            aarch64_engine.invalidateAllTranslations();
        },
        .riscv64 => {
            const riscv64_engine = @import("riscv64_engine.zig");
            riscv64_engine.invalidateAllTranslations();
        },
        .mips64el => {
            const mips64_engine = @import("mips64_engine_stub.zig");
            mips64_engine.invalidateAllTranslations();
        },
        else => {},
    }
    klog.info("wow64: all translation caches invalidated", .{});
}

pub fn shutdownWow64() void {
    wow64_initialized = false;
    wow64_init_status = ntdll.STATUS_SUCCESS;

    switch (builtin.cpu.arch) {
        .loongarch64 => {
            const la64_engine = @import("la64_engine.zig");
            la64_engine.engineShutdown();
        },
        .aarch64 => {
            const aarch64_engine = @import("aarch64_engine.zig");
            aarch64_engine.engineShutdown();
        },
        .riscv64 => {
            const riscv64_engine = @import("riscv64_engine.zig");
            riscv64_engine.engineShutdown();
        },
        .mips64el => {
            const mips64_engine = @import("mips64_engine_stub.zig");
            mips64_engine.engineShutdown();
        },
        else => {},
    }

    klog.info("wow64: shutdown complete", .{});
}

pub fn isInitialized() bool {
    return wow64_initialized;
}

pub fn getInitStatus() ntdll.NTSTATUS {
    return wow64_init_status;
}
