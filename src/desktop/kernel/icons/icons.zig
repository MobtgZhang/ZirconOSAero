//! Desktop icons — Windows 7 Aero (`src/desktop/aero/resources/icons/`)
//!
//! 现在使用 SVG 光栅化的 RGBA 图标数据（通过 build 嵌入）替代硬编码像素数组。

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const shared_icons = @import("../../icons/root.zig");
const svg_data = @import("svg_data");

/// 图标数据返回值类型（统一使用命名类型避免匿名结构体类型不匹配）
const IconDataPtr = struct { rgba: [*]const u8, w: u32, h: u32 };

fn clampIconCoordToI32(v: i64) i32 {
    const min32 = @as(i64, std.math.minInt(i32));
    const max32 = @as(i64, std.math.maxInt(i32));
    const clamped = if (v < min32) min32 else if (v > max32) max32 else v;
    return @intCast(clamped);
}

fn rgb(r: u32, g: u32, b: u32) u32 {
    return b | (g << 8) | (r << 16);
}

/// 与 `src/desktop/aero/src/resource_loader.zig` 内置图标 ID 一致（1–32）。
/// 1–25 与 `icon_resource_ids.PeIconId` / win32 ICO 打包对齐；26–32 为 Explorer 导航/库扩展（内核位图-only，`peIdForLogicalIcon` 返回 null）。
pub const IconId = enum(u8) {
    computer = 1,
    documents = 2,
    recycle_bin = 3,
    terminal = 4,
    network = 5,
    browser = 6,
    settings = 7,
    calculator = 8,
    text_editor = 9,
    pictures = 10,
    music = 11,
    folder = 12,
    control_panel = 13,
    file = 14,
    user = 15,
    lock = 16,
    shutdown = 17,
    recycle_bin_full = 18,
    drive_fixed = 19,
    drive_removable = 20,
    drive_optical = 21,
    printer = 22,
    info = 23,
    warning = 24,
    err = 25,
    favorites = 26,
    shell_desktop = 27,
    downloads = 28,
    recent_places = 29,
    library_root = 30,
    videos = 31,
    homegroup = 32,
};

pub const ThemeStyle = enum(u8) {
    aero = 0,
};

pub const ICON_PX_SIZE: u32 = 16;

pub const IconNameInfo = struct {
    pe_name: ?[]const u8,
};

pub fn iconNameInfo(id: IconId) IconNameInfo {
    return .{ .pe_name = shared_icons.icoBasenameForIcon(id) };
}

/// 每位图 ID 均有独立 16×16 内嵌字形（1–32）；不再降级到 1–13。
pub fn bitmapIconId(id: IconId) IconId {
    return id;
}

pub fn drawIcon(id: IconId, screen_x: i32, screen_y: i32, scale: u32, hover: bool) void {
    drawThemedIcon(id, screen_x, screen_y, scale, .aero, hover);
}

pub fn drawThemedIcon(id: IconId, screen_x: i32, screen_y: i32, scale: u32, _: ThemeStyle, hover: bool) void {
    if (hover) {
        drawAeroIconHover(bitmapIconId(id), screen_x, screen_y, scale);
    } else {
        drawAeroIcon(bitmapIconId(id), screen_x, screen_y, scale);
    }
}

pub fn getIconTotalSize(scale: u32) i32 {
    const s: u64 = if (scale < 1) 1 else @as(u64, scale);
    const prod = @as(u64, ICON_PX_SIZE) * s;
    const capped = @min(prod, @as(u64, @intCast(std.math.maxInt(i32))));
    return @intCast(capped);
}

// ─────────────────────────────────────────────────────────────────────────────
// SVG 图标渲染：将嵌入的 RGBA 图标数据 blit 到帧缓冲
// ─────────────────────────────────────────────────────────────────────────────

pub fn getSvgIconData(id: IconId) IconDataPtr {
    const v = @intFromEnum(id);
    return switch (v) {
        1 => IconDataPtr{ .rgba = svg_data.ic_01_computer.ptr,        .w = svg_data.ic_01_computer_w,        .h = svg_data.ic_01_computer_h        },
        2 => IconDataPtr{ .rgba = svg_data.ic_02_documents.ptr,       .w = svg_data.ic_02_documents_w,       .h = svg_data.ic_02_documents_h       },
        3 => IconDataPtr{ .rgba = svg_data.ic_03_recycle_bin.ptr,     .w = svg_data.ic_03_recycle_bin_w,     .h = svg_data.ic_03_recycle_bin_h     },
        4 => IconDataPtr{ .rgba = svg_data.ic_04_terminal.ptr,        .w = svg_data.ic_04_terminal_w,        .h = svg_data.ic_04_terminal_h        },
        5 => IconDataPtr{ .rgba = svg_data.ic_05_network.ptr,         .w = svg_data.ic_05_network_w,         .h = svg_data.ic_05_network_h         },
        6 => IconDataPtr{ .rgba = svg_data.ic_06_browser.ptr,         .w = svg_data.ic_06_browser_w,         .h = svg_data.ic_06_browser_h         },
        7 => IconDataPtr{ .rgba = svg_data.ic_07_settings.ptr,       .w = svg_data.ic_07_settings_w,       .h = svg_data.ic_07_settings_h       },
        8 => IconDataPtr{ .rgba = svg_data.ic_08_calculator.ptr,     .w = svg_data.ic_08_calculator_w,     .h = svg_data.ic_08_calculator_h     },
        9 => IconDataPtr{ .rgba = svg_data.ic_09_text_editor.ptr,    .w = svg_data.ic_09_text_editor_w,    .h = svg_data.ic_09_text_editor_h    },
        10 => IconDataPtr{ .rgba = svg_data.ic_10_pictures.ptr,        .w = svg_data.ic_10_pictures_w,        .h = svg_data.ic_10_pictures_h        },
        11 => IconDataPtr{ .rgba = svg_data.ic_11_music.ptr,           .w = svg_data.ic_11_music_w,           .h = svg_data.ic_11_music_h           },
        12 => IconDataPtr{ .rgba = svg_data.ic_12_folder.ptr,          .w = svg_data.ic_12_folder_w,          .h = svg_data.ic_12_folder_h          },
        13 => IconDataPtr{ .rgba = svg_data.ic_13_control_panel.ptr,  .w = svg_data.ic_13_control_panel_w,  .h = svg_data.ic_13_control_panel_h  },
        14 => IconDataPtr{ .rgba = svg_data.ic_14_file.ptr,           .w = svg_data.ic_14_file_w,           .h = svg_data.ic_14_file_h           },
        15 => IconDataPtr{ .rgba = svg_data.ic_15_user.ptr,           .w = svg_data.ic_15_user_w,           .h = svg_data.ic_15_user_h           },
        16 => IconDataPtr{ .rgba = svg_data.ic_16_lock.ptr,           .w = svg_data.ic_16_lock_w,           .h = svg_data.ic_16_lock_h           },
        17 => IconDataPtr{ .rgba = svg_data.ic_17_shutdown.ptr,        .w = svg_data.ic_17_shutdown_w,        .h = svg_data.ic_17_shutdown_h        },
        18 => IconDataPtr{ .rgba = svg_data.ic_18_recycle_bin_full.ptr, .w = svg_data.ic_18_recycle_bin_full_w, .h = svg_data.ic_18_recycle_bin_full_h },
        19 => IconDataPtr{ .rgba = svg_data.ic_19_drive_fixed.ptr,    .w = svg_data.ic_19_drive_fixed_w,    .h = svg_data.ic_19_drive_fixed_h    },
        20 => IconDataPtr{ .rgba = svg_data.ic_20_drive_removable.ptr, .w = svg_data.ic_20_drive_removable_w, .h = svg_data.ic_20_drive_removable_h },
        21 => IconDataPtr{ .rgba = svg_data.ic_21_drive_optical.ptr,   .w = svg_data.ic_21_drive_optical_w,   .h = svg_data.ic_21_drive_optical_h   },
        22 => IconDataPtr{ .rgba = svg_data.ic_22_printer.ptr,         .w = svg_data.ic_22_printer_w,         .h = svg_data.ic_22_printer_h         },
        23 => IconDataPtr{ .rgba = svg_data.ic_23_info.ptr,            .w = svg_data.ic_23_info_w,            .h = svg_data.ic_23_info_h            },
        24 => IconDataPtr{ .rgba = svg_data.ic_24_warning.ptr,         .w = svg_data.ic_24_warning_w,         .h = svg_data.ic_24_warning_h         },
        25 => IconDataPtr{ .rgba = svg_data.ic_25_err.ptr,             .w = svg_data.ic_25_err_w,             .h = svg_data.ic_25_err_h             },
        26 => IconDataPtr{ .rgba = svg_data.ic_26_favorites.ptr,       .w = svg_data.ic_26_favorites_w,       .h = svg_data.ic_26_favorites_h       },
        27 => IconDataPtr{ .rgba = svg_data.ic_27_shell_desktop.ptr,    .w = svg_data.ic_27_shell_desktop_w,    .h = svg_data.ic_27_shell_desktop_h    },
        28 => IconDataPtr{ .rgba = svg_data.ic_28_downloads.ptr,       .w = svg_data.ic_28_downloads_w,       .h = svg_data.ic_28_downloads_h       },
        29 => IconDataPtr{ .rgba = svg_data.ic_29_recent_places.ptr,   .w = svg_data.ic_29_recent_places_w,   .h = svg_data.ic_29_recent_places_h   },
        30 => IconDataPtr{ .rgba = svg_data.ic_30_library_root.ptr,    .w = svg_data.ic_30_library_root_w,    .h = svg_data.ic_30_library_root_h    },
        31 => IconDataPtr{ .rgba = svg_data.ic_31_videos.ptr,          .w = svg_data.ic_31_videos_w,          .h = svg_data.ic_31_videos_h          },
        32 => IconDataPtr{ .rgba = svg_data.ic_32_homegroup.ptr,       .w = svg_data.ic_32_homegroup_w,       .h = svg_data.ic_32_homegroup_h       },
        else => IconDataPtr{
            .rgba = svg_data.ic_01_computer.ptr,
            .w = svg_data.ic_01_computer_w,
            .h = svg_data.ic_01_computer_h,
        },
    };
}

/// 将 SVG RGBA 图标缩放绘制到指定区域（使用最近邻缩放）
fn drawSvgIcon(id: IconId, dest_x: i32, dest_y: i32, dest_w: i32, dest_h: i32) void {
    if (dest_w <= 0 or dest_h <= 0) return;
    const icon = getSvgIconData(id);
    if (icon.w == 0 or icon.h == 0) return;

    const scale_x: f64 = @as(f64, @floatFromInt(dest_w)) / @as(f64, @floatFromInt(icon.w));
    const scale_y: f64 = @as(f64, @floatFromInt(dest_h)) / @as(f64, @floatFromInt(icon.h));
    const scale: f64 = @min(scale_x, scale_y);

    const scaled_w: i32 = @intFromFloat(@as(f64, @floatFromInt(icon.w)) * scale);
    const scaled_h: i32 = @intFromFloat(@as(f64, @floatFromInt(icon.h)) * scale);
    const final_x = dest_x + @divTrunc(dest_w - scaled_w, 2);
    const final_y = dest_y + @divTrunc(dest_h - scaled_h, 2);

    fb.blitRgbaScaled(icon.rgba, icon.w, icon.h, final_x, final_y, scaled_w, scaled_h);
}

/// 绘制 Aero 图标：透明背景 + SVG 图标内容 + 悬停高亮边框
fn drawAeroIcon(id: IconId, screen_x: i32, screen_y: i32, scale: u32) void {
    const s: i32 = if (scale < 1) 1 else @intCast(scale);
    const sz: i32 = 16 * s;
    drawSvgIcon(id, screen_x, screen_y, sz, sz);
}

/// 绘制带悬停高亮的 Aero 图标
fn drawAeroIconHover(id: IconId, screen_x: i32, screen_y: i32, scale: u32) void {
    const s: i32 = if (scale < 1) 1 else @intCast(scale);
    const sz: i32 = 16 * s;
    drawSvgIcon(id, screen_x, screen_y, sz, sz);
    const border_color: u32 = rgb(0xA0, 0xC8, 0xFF);
    fb.drawRect(screen_x, screen_y, sz, sz, border_color);
}

test "IconId logical 1..=32 matches SVG icon data" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(IconId.computer));
    try std.testing.expectEqual(@as(u8, 32), @intFromEnum(IconId.homegroup));
}

/// 绘制开始 Orb — 支持悬停发光和按压缩下动画。
pub fn drawStartOrb(dest_x: i32, dest_y: i32, dest_size: i32, hover: f32, press: f32) void {
    if (dest_size <= 0) return;

    const src_w: u32 = svg_data.start_orb_w;
    const src_h: u32 = svg_data.start_orb_h;
    if (src_w == 0 or src_h == 0) return;

    // 按压效果：缩小尺寸 + 偏移
    const press_scale: f64 = 1.0 - @as(f64, press) * 0.15; // 最多缩小 15%
    const press_offset_x: i32 = @intFromFloat(@as(f64, @floatFromInt(dest_size)) * (1.0 - press_scale) * 0.5);
    const press_offset_y: i32 = @intFromFloat(@as(f64, @floatFromInt(dest_size)) * (1.0 - press_scale) * 0.5);

    // 实际渲染尺寸
    const actual_size: i32 = @intFromFloat(@as(f64, @floatFromInt(dest_size)) * press_scale);
    const actual_x = dest_x + press_offset_x;
    const actual_y = dest_y + press_offset_y;

    // 悬停发光效果：先画外发光圈
    if (hover > 0.0) {
        const glow_alpha: u8 = @intFromFloat(hover * 80.0); // 最多 80 alpha
        const glow_size: i32 = @intFromFloat(@as(f64, @floatFromInt(actual_size)) * (1.0 + hover * 0.2));
        const glow_x = actual_x - @divTrunc(glow_size - actual_size, 2);
        const glow_y = actual_y - @divTrunc(glow_size - actual_size, 2);
        fb.blendTintRect(glow_x, glow_y, glow_size, glow_size, rgb(0x50, 0xA0, 0xE0), glow_alpha, 255);
    }

    // 缩放算法与 drawSvgIcon 完全相同
    const scale_x: f64 = @as(f64, @floatFromInt(actual_size)) / @as(f64, @floatFromInt(src_w));
    const scale_y: f64 = @as(f64, @floatFromInt(actual_size)) / @as(f64, @floatFromInt(src_h));
    const scale: f64 = @min(scale_x, scale_y);

    const scaled_w: i32 = @intFromFloat(@as(f64, @floatFromInt(src_w)) * scale);
    const scaled_h: i32 = @intFromFloat(@as(f64, @floatFromInt(src_h)) * scale);
    const final_x = actual_x + @divTrunc(actual_size - scaled_w, 2);
    const final_y = actual_y + @divTrunc(actual_size - scaled_h, 2);

    // 直接使用嵌入的 RGBA 指针
    const orb_ptr: [*]const u8 = @ptrCast(&svg_data.start_orb);
    fb.blitRgbaScaled(orb_ptr, src_w, src_h, final_x, final_y, scaled_w, scaled_h);

    // 按压加深效果：叠加暗色层
    if (press > 0.0) {
        const press_alpha: u8 = @intFromFloat(press * 60.0); // 最多 60 alpha
        fb.blendTintRect(actual_x, actual_y, actual_size, actual_size, rgb(0x00, 0x20, 0x60), press_alpha, 255);
    }
}
