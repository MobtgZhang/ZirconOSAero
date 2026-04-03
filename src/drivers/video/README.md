# 视频 / 桌面显示子系统（`src/drivers/video`）

NT 6.1 风格的帧缓冲迷你端口、内核壳层 Aero 渲染、VirtIO-GPU 与厂商 GPU 探测入口。**对外稳定导入**：优先 `@import("drivers/video/root.zig")` 或 `drivers.mod.video`（与 `root.zig` 再导出一致），避免在内核其它目录写死深层相对路径。

## 目录树（摘要）

| 目录 | 职责 |
|------|------|
| `core/` | 帧缓冲、显示管理器、DWM、合成器、光标层、flip journal、桌面 FB 解析、`wddm_abstraction.zig`、`gpu_device.zig` |
| `desktop/` | Aero 壳：开始菜单、内置应用、主题/材质、壁纸嵌入、图标、托盘、软件光标位图、CJK 字形等 |
| `virtio/` | VirtIO-GPU 规范常量与 PCI 传输（`virtio_gpu_spec.zig`、`virtio_gpu_pci.zig`） |
| `legacy/` | VGA、HDMI 连接器桩 |
| `vendor/` | `amd/`、`intel/`、`nvidia/`、`loongson/` 芯片族与 handoff 辅助 |
| 根目录 | `root.zig`（再导出）、`amd_igpu.zig`、`intel_igpu.zig`、`nvidia_gpu.zig`、`loongson_igpu.zig` 薄入口 |

## 分辨率验证脚本

- x86_64：`scripts/test_x86_resolution_matrix.sh`（`--quick` 为三档）
- LoongArch：`scripts/test_loongarch_resolution_matrix.sh`

与根目录 `build.conf` 注释表档位一致；通过 `zig -Dzbm_preferred_fb_width/height` 注入，不修改仓内单行 `RESOLUTION` 惯例。

## 参考文档

- [docs/cn/AeroDesktopRuntime.md](../../../docs/cn/AeroDesktopRuntime.md) §4.2（分辨率与 RAM）
- [docs/cn/SOFTWARE_COMPOSITOR_WDDM.md](../../../docs/cn/SOFTWARE_COMPOSITOR_WDDM.md)（VirtIO scanout 上界、`BACK_BUF_MAX`）
- [docs/REPRODUCE_BUILD.md](../../../docs/REPRODUCE_BUILD.md)（本地与 CI 命令）
