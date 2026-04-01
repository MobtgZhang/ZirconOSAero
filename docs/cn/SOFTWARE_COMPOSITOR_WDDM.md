# 软件合成器、Aero 与 WDDM（诚实说明）

## 当前定位

- **本仓库的 Aero**：主要为 **CPU / 帧缓冲** 路径上的窗口合成与主题资源（见 `src/drivers/video/`、`dwm.zig`、`renderer_aero.zig`）。  
- **Windows 7 的 DWM**：依赖 **WDDM** 用户态与内核协作、GPU 命令缓冲与桌面合成 — **本仓库未实现 WDDM 驱动模型**。

## MVP 软件合成器（路线）

1. **图层栈**：全屏桌面 → 壁纸 → 窗口 back-buffer → 光标（Z-order 与 `DesktopManagerSpec` 对齐）。  
2. **脏矩形**：在 `compositor_config_epoch` 与显示路径上减少全屏 blit（已有部分 trace / 握手位）。  
3. **与 user32 边界**：user32 负责单窗消息与 NC；合成器负责跨窗 Z-order 与 damage 聚合。

## GPU 路线（QEMU / 真机）

- **Virtio-GPU**：作为可移植的 **非 WDDM** 加速台阶（VirtIO 规范 + 本内核 PCI 枚举）。  
- 真机 **Intel/AMD/NVIDIA** 的 KMS 类路径为独立里程碑，与 NT 显示驱动 **无源码级对齐义务**。

## 参考

Microsoft Learn — Desktop Window Manager **概述**（概念）；算法与代码须原创。
