// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero — Virtio-Net 驱动占位（未接入 PCI 枚举与 IRP）。
// 路线图：docs/cn/ARCH_SMP_NET_MATRIX.md
//
// This is an independent clean-room implementation.
// Reference: VirtIO 1.x network device specification.

/// 将来 `virtio_net` 初始化入口；当前未从 `drivers/mod.zig` 引用，避免未完成路径参与链接。
pub fn initPlaceholder() void {}
