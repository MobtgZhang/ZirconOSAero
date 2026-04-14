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
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/root.zig
// Purpose: Stable re-exports for kernel / shell; prefer this over deep `@import("drivers/video/core/...")` paths.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.

pub const framebuffer = @import("core/framebuffer.zig");
pub const display = @import("core/display.zig");
pub const display_primitives = @import("core/display/display_primitives.zig");
pub const dwm = @import("core/dwm.zig");
pub const dwm_compositor = @import("core/dwm_compositor.zig");
pub const display_flip_journal = @import("core/display_flip_journal.zig");
pub const display_backend = @import("core/display_backend.zig");
pub const gpu_device = @import("core/gpu_device.zig");
pub const wddm_abstraction = @import("core/wddm_abstraction.zig");
pub const desktop_fb_resolve = @import("core/desktop_fb_resolve.zig");
pub const cursor_plane = @import("core/cursor_plane.zig");

pub const startmenu = @import("../../desktop/kernel/startmenu/root.zig");
pub const builtin_apps = @import("../../desktop/kernel/shell/root.zig");
pub const shell_strings = @import("../../desktop/kernel/strings/root.zig");
pub const icons = @import("../../desktop/kernel/icons/root.zig");
pub const material = @import("../../desktop/kernel/material/root.zig");
pub const theme = @import("../../desktop/kernel/theme/root.zig");
pub const renderer_aero = @import("../../desktop/kernel/renderer_aero/root.zig");
pub const wallpaper_bitmap = @import("../../desktop/kernel/wallpaper/root.zig");
pub const cjk_font = @import("../../desktop/kernel/font/cjk_font.zig");
pub const aero_tray = @import("../../desktop/kernel/taskbar/root.zig");
pub const aero_cursor_shape = @import("../../desktop/kernel/cursor/root.zig");

pub const virtio_gpu_spec = @import("virtio/virtio_gpu_spec.zig");
pub const virtio_gpu_pci = @import("virtio/virtio_gpu_pci.zig");

pub const vga = @import("legacy/vga.zig");
pub const hdmi = @import("legacy/hdmi.zig");

pub const intel_igpu = @import("intel_igpu.zig");
pub const amd_igpu = @import("amd_igpu.zig");
pub const nvidia_gpu = @import("nvidia_gpu.zig");
pub const loongson_igpu = @import("loongson_igpu.zig");
