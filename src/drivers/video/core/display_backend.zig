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
// Module: src/drivers/video/core/display_backend.zig
// Purpose: Runtime display present backend (GOP linear FB vs VirtIO scanout); not WDDM.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: docs/cn/SOFTWARE_COMPOSITOR_WDDM.md

const build_options = @import("build_options");

/// 与合成器输出对接的呈现路径（阶段 4：软/硬切换观测点）。
pub const BackendKind = enum(u8) {
    gop_linear = 0,
    virtio_scanout = 1,
};

var active_backend: BackendKind = .gop_linear;

pub fn setActiveBackend(k: BackendKind) void {
    active_backend = k;
}

pub fn getActiveBackend() BackendKind {
    return active_backend;
}

/// 在 `display` / VirtIO bringup 之后调用：`scanout_active` 为真时使用 `virtio_scanout`（除非 `-Dforce_gop_present`）。
pub fn syncFromVirtioScanout(scanout_active: bool) void {
    if (build_options.force_gop_present) {
        active_backend = .gop_linear;
        return;
    }
    active_backend = if (scanout_active) .virtio_scanout else .gop_linear;
}
