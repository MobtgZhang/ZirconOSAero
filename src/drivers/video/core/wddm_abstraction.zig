// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/core/wddm_abstraction.zig
// Purpose: WDDM **概念**边界（内核 present / 用户态合成 / KMD 职责）— 非二进制兼容微软 KMD。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: Microsoft Learn — Windows Display Driver Model (WDDM) overview
//
//! 分层（与 `docs/cn/DesktopManagerSpec.md` 方案 B 一致）：
//! - **本文件**：仅文档化策略常量与将来 IOCTL/DDI 挂钩点；不生成 WDDM 用户态驱动协议。
//! - **`display.zig` / `dwm_compositor.zig`**：CPU 合成与 GOP present。
//! - **厂商桩**（`amd/`、`intel/`、`nvidia/`）：PCI 探测与 handoff，可逐步接共享表面与 command buffer 契约。

pub const WddmPhase = enum(u8) {
    cpu_composite_only = 0,
    shared_surface_stub = 1,
    vendor_command_ring = 2,
};

/// 编译期路线图锚点（与 `display` 运行时 `classifyVirtioRuntimePhase` 独立）。
pub const current_phase: WddmPhase = .cpu_composite_only;

/// 由 `display.initAeroDwm` / 诊断根据 VirtIO-GPU 状态打印的运行时分相（非二进制 WDDM）。
pub const WddmRuntimePhase = enum {
    cpu_composite_only,
    virtio_scanout_flat,
    virtio_scanout_multipage,
    virgl_context_up,
};

pub fn classifyVirtioRuntimePhase(
    scanout_active: bool,
    multipage_backing: bool,
    virgl_ctx_ready: bool,
) WddmRuntimePhase {
    if (virgl_ctx_ready) return .virgl_context_up;
    if (scanout_active and multipage_backing) return .virtio_scanout_multipage;
    if (scanout_active) return .virtio_scanout_flat;
    return .cpu_composite_only;
}
