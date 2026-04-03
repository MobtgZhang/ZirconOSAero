// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/core/display_backend.zig
// Purpose: Runtime display present backend (GOP linear FB vs VirtIO scanout); not WDDM.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: docs/cn/SOFTWARE_COMPOSITOR_WDDM.md

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

/// 在 `display` / VirtIO bringup 之后调用：`scanout_active` 为真时使用 `virtio_scanout`。
pub fn syncFromVirtioScanout(scanout_active: bool) void {
    active_backend = if (scanout_active) .virtio_scanout else .gop_linear;
}
