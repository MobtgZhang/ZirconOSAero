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
//! - **`display_backend.zig`**：运行时 `gop_linear` / `virtio_scanout`（与下文 `WddmRuntimePhase` 日志互补，非 WDDM IOCTL）。

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
    /// `CMD_SUBMIT_3D` 空提交至少一次成功（MVP；非 WDDM IOCTL、无模糊卸载）。
    virgl_submit3d_noop_ok,
};

pub fn classifyVirtioRuntimePhase(
    scanout_active: bool,
    multipage_backing: bool,
    virgl_ctx_ready: bool,
    submit3d_noop_ok: bool,
) WddmRuntimePhase {
    if (submit3d_noop_ok) return .virgl_submit3d_noop_ok;
    if (virgl_ctx_ready) return .virgl_context_up;
    if (scanout_active and multipage_backing) return .virtio_scanout_multipage;
    if (scanout_active) return .virtio_scanout_flat;
    return .cpu_composite_only;
}

/// **非 WDDM**：合成责任划分（阶段 4 / `SOFTWARE_COMPOSITOR_WDDM.md`）。与 `display_backend.BackendKind` 互补 — 后者仅描述 **像素从哪送出**。
pub const CompositorBackend = enum(u8) {
    /// GOP/线性帧缓冲；或未协商 VirtIO scanout。
    cpu_full = 0,
    /// CPU 合成 + VirtIO `SET_SCANOUT` 呈现（盒式模糊仍在 CPU，除非 Phase4-Plus 委托成功）。
    cpu_with_virtio_present = 1,
    /// VirGL 空/非空提交已 bring-up；允许尝试 `tryVirglBlurBoxDelegation`（当前仍恒返回 false）。
    future_gpu_assist = 2,
};

/// `force_gop` 来自 `-Dforce_gop_present`：`true` 时视为 **cpu_full**（与 `display_backend.syncFromVirtioScanout` 一致）。
pub fn classifyCompositorBackend(
    force_gop: bool,
    scanout_active: bool,
    submit3d_noop_ok: bool,
) CompositorBackend {
    if (submit3d_noop_ok) return .future_gpu_assist;
    if (!force_gop and scanout_active) return .cpu_with_virtio_present;
    return .cpu_full;
}
