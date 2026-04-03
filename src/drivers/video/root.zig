// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/root.zig
// Purpose: Stable re-exports for kernel / shell; prefer this over deep `@import("drivers/video/core/...")` paths.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.

pub const framebuffer = @import("core/framebuffer.zig");
pub const display = @import("core/display.zig");
pub const dwm = @import("core/dwm.zig");
pub const dwm_compositor = @import("core/dwm_compositor.zig");
pub const display_flip_journal = @import("core/display_flip_journal.zig");
pub const display_backend = @import("core/display_backend.zig");
pub const gpu_device = @import("core/gpu_device.zig");
pub const wddm_abstraction = @import("core/wddm_abstraction.zig");
pub const desktop_fb_resolve = @import("core/desktop_fb_resolve.zig");
pub const cursor_plane = @import("core/cursor_plane.zig");

pub const startmenu = @import("desktop/startmenu.zig");
pub const builtin_apps = @import("desktop/builtin_apps.zig");
pub const shell_strings = @import("desktop/shell_strings.zig");
pub const icons = @import("desktop/icons.zig");
pub const material = @import("desktop/material.zig");
pub const theme = @import("desktop/theme.zig");
pub const renderer_aero = @import("desktop/renderer_aero.zig");
pub const wallpaper_bitmap = @import("desktop/wallpaper_bitmap.zig");
pub const cjk_font = @import("desktop/cjk_font.zig");
pub const aero_tray = @import("desktop/aero_tray.zig");
pub const aero_cursor_shape = @import("desktop/aero_cursor_shape.zig");

pub const virtio_gpu_spec = @import("virtio/virtio_gpu_spec.zig");
pub const virtio_gpu_pci = @import("virtio/virtio_gpu_pci.zig");

pub const vga = @import("legacy/vga.zig");
pub const hdmi = @import("legacy/hdmi.zig");

pub const intel_igpu = @import("intel_igpu.zig");
pub const amd_igpu = @import("amd_igpu.zig");
pub const nvidia_gpu = @import("nvidia_gpu.zig");
pub const loongson_igpu = @import("loongson_igpu.zig");
