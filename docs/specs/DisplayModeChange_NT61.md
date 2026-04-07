# 显示子系统模式变更规格（NT6.1 风格，Clean Room）

本文档为本项目 **原创** 行为规格，用于内核显示栈、`IOCTL_DISPLAY_SET_MODE` 与 LoongArch ramfb / VirtIO-GPU 协作。不复制 WDK 头文件布局。

## 1. 目标

- 在 **桌面已就绪**（`display_state == desktop_mode` 且帧缓冲已初始化）后，允许将 **逻辑分辨率** 切换为新的 `width × height`（32 bpp 为主路径）。  
- 失败时返回 `NTSTATUS`，**不保证** 回滚到前一模式（调用方应保存参数并在失败时重试旧值）。

## 2. IOCTL：`IOCTL_DISPLAY_SET_MODE`（0x000A0004）

- **缓冲方式**：`METHOD_BUFFERED` 语义（当前内核 IRP 使用 `buffer_ptr` + `buffer_size`）。  
- **最小输入长度**：`sizeof(DisplaySetModeRequestV1)`（32 字节，见下）。  
- **成功**：`STATUS_SUCCESS`，`information = 0`。  
- **错误**：  
  - `STATUS_BUFFER_TOO_SMALL`：`buffer_size` 不足。  
  - `STATUS_INVALID_PARAMETER`：`version != 1`、宽高超出允许范围、`bpp != 32`、`pitch` 非法。  
  - `STATUS_INVALID_DEVICE_REQUEST`：非桌面模式或未初始化帧缓冲。  
  - `STATUS_INSUFFICIENT_RESOURCES`：LoongArch ramfb 新尺寸超过引导期预留的扫描区字节数。  
  - `STATUS_NOT_SUPPORTED`：非 ramfb 且无法在原物理缓冲内容纳新尺寸（例如 GOP 固定表面缩小策略未实现）。

## 3. 结构体 `DisplaySetModeRequestV1`（little-endian，按 C ABI 对齐）


| 偏移  | 类型    | 字段         | 说明                                                            |
| --- | ----- | ---------- | ------------------------------------------------------------- |
| 0   | u32   | version    | 必须为 `1`                                                       |
| 4   | u32   | flags      | 保留，填 `0`                                                      |
| 8   | u32   | width      | 逻辑宽，建议 320–16384                                              |
| 12  | u32   | height     | 逻辑高，建议 240–16384                                              |
| 16  | u8    | bpp        | 当前仅支持 `32`                                                    |
| 17  | u8    | pixel_bgr  | `1` = BGRx 顺序（与 UEFI GOP 常见一致）；`0` = RGBx                     |
| 18  | u8[2] | reserved   | 填 0                                                           |
| 20  | u32   | pitch      | 字节行距；`0` 表示 `width * 4`                                       |
| 24  | u64   | fb_address | 帧缓冲 **物理** 基址；`0` 表示「保持当前基址」（LoongArch ramfb 仍为 `RAMFB_PHYS`） |


**LoongArch64 补充**：`fb_address != 0` 且与当前桌面表面基址不同时，须 **页对齐**，并调用 `hal/loongarch64/ramfb.zig` 的 `runtimeReconfigureAtGuestPhys`；`width×height×4` 不得超过引导期 `guest_reserved_scanout_bytes`。调用方须保证该物理区间已映射且未被帧分配器占用。

Zig 侧使用 `extern struct` 与 `@sizeOf` 一致；主机测试须保证 8 字节对齐无 padding 问题（当前布局 32 字节）。

## 4. 内核应用顺序（与实现一致）

1. `cursor_plane.invalidate()`
2. 若 VirtIO-GPU scanout 已激活：**detach backing → unref scanout 资源**（见 VirtIO GPU 规范），再重建。
3. LoongArch：若当前扫描输出为 ramfb（物理基址为 `RAMFB_PHYS`），调用 `ramfb.runtimeReconfigure`；受 `guest_reserved_scanout_bytes` 约束。
4. `framebuffer.init(phys, w, h, pitch, bpp, pixel_bgr)`（已注册驱动时不重复注册）。
5. 更新 `desktop_ctx.surface`，`dwm.applyPlatformAndResolutionTuning(w, h)`。
6. `hdmi.syncFramebufferMode`（桩与元数据）。
7. 鼠标居中、`setScreenBounds`、`virtio_input_pci.resetPointerBaseline`、x86 上 `reassertStreamEnable`（若适用）、`syncCursorFromMouse`。
8. 若 GPU 已 bring-up：`trySetupScanoutFromFramebuffer()`。

## 5. LoongArch ramfb 预留

- 引导期在 `main.zig` 对 `RAMFB_PHYS` 调用 `markPhysRangeUsed` 的字节数取 `**max(启动首选, 3840×2160×4)`**（与 `virtio_gpu_spec.max_scanout_`* 一致），并 `ramfb.noteGuestReservedScanout(...)`。  
- 运行期 `runtimeReconfigure` 若 `width*height*4` 超过该预留，返回失败（`STATUS_INSUFFICIENT_RESOURCES`）。

## 6. 回归矩阵（手工 / QEMU）


| 场景            | QEMU 设备                              | 操作                                       |
| ------------- | ------------------------------------ | ---------------------------------------- |
| LA64 ramfb    | `-device ramfb`                      | 启动 1024×768 → IOCTL 1280×720 → 应成功（在预留内） |
| LA64 ramfb 超限 | 同上，预留未扩大                             | IOCTL 3840×2160 若超预留应失败                  |
| VirtIO-GPU    | `virtio-gpu-pci` + guest RAM scanout | 模式切换后仍应有像素更新（RESOURCE_FLUSH）             |
| VirtIO 输入     | `virtio-tablet` 等                    | 切换后指针边界与 ABS baseline 重置，无「卡角」           |


## 7. 与 NT6.1 的关系

 IOCTL 码与 `NTSTATUS` 数值与项目既有 `io.zig` / `ntdll` 子集 **观测一致**；结构体布局 **非** 微软官方定义，不得与 WDK 中任意 `DISPLAY`_* 结构混用。