# VirtIO-GPU VirGL MVP（公开规范边界）

## 目标

在 **不实现 WDDM 二进制协议**、不参考 Windows/ReactOS/Wine 显示驱动源码的前提下，为 Aero 合成提供 **可选 GPU 模糊/着色器** 台阶。知识来源：**OASIS VirtIO GPU**、**Linux `uapi/linux/virtio_gpu.h`**（BSD 头文件常量）、**Khronos GL/GLES** 公开规范、**Mesa VirGL** 公开协议描述。

## 当前仓库状态（实现切片）

| 能力 | 状态 |
|------|------|
| 设备特性 low 位 **VIRGL**（bit0）协商 | `virtio_gpu_pci.tryGpuBringup` 内读 `device_feature_select=0` 并写回 `driver_feature` |
| `CMD_CTX_CREATE`（0x0200） | 2D bring-up 成功后发送；成功则 `virgl_ctx_alive` |
| `CMD_SUBMIT_3D` + Gallium/VirGL 命令流 | **未接**；`tryVirglBlurBoxDelegation` 恒 `false`，`dwm.boxBlurRectBudgeted` 仍走 CPU |
| 用户态渲染器 / IOCTL 边界 | 规划中；见 `wddm_abstraction.zig` 的 `WddmRuntimePhase.virgl_context_up` 与 `display` 日志 |

## QEMU 验证建议

- 无 VirGL：`-device virtio-gpu-pci` — 不应因缺失 3D 而失败；串口可无 `CMD_CTX_CREATE ok`。
- 有 VirGL（需主机 EGL/virgl）：`-device virtio-gpu-pci,virgl=on` — 预期 `device offers VIRGL` 与 `CMD_CTX_CREATE ok`（若固件/机器拒绝则回退日志）。

## 后续 MVP 切片（不承诺排期）

1. **最小 `SUBMIT_3D`**：向已创建 context 提交 **noop** 或 **glClear** 类 VirGL 封装（自主编码，不复制 Mesa 源码）。
2. **全屏纹理 resource**：与 scanout 或离屏 `RESOURCE_CREATE_2D` 绑定，作为模糊输入。
3. **用户态**：将命令提交迁出内核，仅保留 **能力协商 + 共享页 DMA 描述**（与 `MM_Section_Roadmap.md` 对齐）。

## WDDM 关系

仅 **概念** 对齐 Microsoft Learn 上「DWM 与 GPU 合成」描述；**无** `DxgkDdi*` 二进制契约实现义务。
