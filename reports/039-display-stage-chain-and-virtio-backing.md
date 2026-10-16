# 问题 #39：显示链路阶段与 VirtIO-GPU backing 校验

## 1. 问题编号

`39`

## 2. 问题位置

- 文件路径：`src/drivers/video/core/framebuffer.zig`
- 函数/模块：`fillFrontBufferVirtioBackingEntries()`、`getFrontBufferPhysContiguousForVirtio()`
- 行号或代码片段：修复前两个函数均包含 `if (len % page != 0) return null;`

相关阶段代码：

- `src/drivers/video/bootvid.zig`
- `src/rtl/bootvid_console.zig`
- `src/arch/x86_64/mod.zig`
- `src/kernel/boot_x86_64.zig`
- `src/kernel/desktop_session.zig`

## 3. 问题描述

VirtIO-GPU backing 检查把“页对齐的物理页”与“帧缓冲总字节数页对齐”混为一谈。1440×900×32bpp 的线性帧缓冲总长为 5184000 字节，不是 4096 的整数倍，因此即使帧缓冲可用，也被错误判定为不能派生 backing entries。

同时，屏幕日志边界必须清楚：UEFI 菜单、内核启动、桌面三个阶段使用不同显示驱动形态；进入桌面后不能继续在屏幕打印 INFO/DEBUG 日志，串口日志则应持续输出。

## 4. 复现路径

1. 构建 x86-64 UEFI ESP。
2. 启动 QEMU 并附加 `virtio-gpu-pci`，以及绑定到该 GPU 的 virtio 输入设备。
3. 在 UEFI 菜单选择 ZirconOSAero。
4. `winload.efi` 完成 `ExitBootServices` 后进入内核启动阶段。
5. 修复前串口日志出现 `VirtIO scanout hints: cannot derive backing entries`。

## 5. 影响范围

- 阻止 1440×900×32bpp 的 VirtIO-GPU scanout 建立。
- 桌面可能继续依赖 UEFI GOP 帧缓冲形态。
- BootVID 激活边界不明确时，内核日志可能污染桌面画面。

## 6. 严重程度

- High

## 7. 可能原因

原代码额外要求整个帧缓冲长度为 4096 整数倍。VirtIO `virtio_gpu_mem_entry.length` 只要求 entry 长度不超过 `u32::MAX`，必要时按上限切分，不要求总长度页对齐。

## 8. 权威参考依据

- QEMU VirtIO-GPU 控制路径：`RESOURCE_CREATE_2D`、`RESOURCE_ATTACH_BACKING`、`SET_SCANOUT`、`RESOURCE_FLUSH`。
- 本项目源码级运行时日志与 QEMU 复现结果。
- 本条未声称已使用 REA 对 Windows 7 镜像完成函数级二进制对照。Windows 7 的实际图形栈包含更完整的 `bootvid.sys`、`win32k.sys`、DWM/WDDM 路径，当前实现只对齐阶段边界，不声称一比一等价。
- `/home/mobtgzhang/api.json` 是 REA provider 配置；本条未从中提取 Windows API 行为依据。

## 9. 建议修复方案

- 删除两个 backing 查询函数中的总长度页对齐检查。
- 帧缓冲长度按 `u32::MAX` 上限切分 entry。
- BootVID 初始化后设置 active 标志；桌面首帧渲染前停用。
- x86-64 屏幕 console 输出只在 BootVID active 时写帧缓冲，串口输出保持不变。
- 进入桌面主循环时设置 `klog.setDesktopMode(true)` 与 `klog.setDesktopMinLevel(.warning)`。

## 10. 验证方法

已执行：

```bash
zig fmt src/drivers/video/core/framebuffer.zig src/drivers/video/bootvid.zig src/rtl/bootvid_console.zig src/kernel/desktop_session.zig src/kernel/boot_x86_64.zig
zig build test
make build ARCH=x86_64
make build ARCH=aarch64
make build ARCH=riscv64
make build ARCH=mips64el
git diff --check
```

已用 QEMU TCG 运行 120 秒，关键串口日志包括：

```text
[*] winload.efi opened
[*] GOP Framebuffer: 1440x900x32 pitch_B=5760
: BootVID: active (framebuffer 1440x900@32bpp, pitch=5760)
: I/O: Driver '\Driver\Bootvid' registered (idx=1)
: Framebuffer: heap back buffer 1266 pages phys=0x9723000 (5184000 bytes)
: VirtIO scanout hints: front buffer single contiguous GPA span (legacy attach path ok)
: Process: 'dwm.exe' created (PID=3, system=true)
```

后续修复 uncached DMA 映射后，已在 QEMU TCG 45 秒运行中启用 `virtio_gpu*` trace 复测。设备端 trace 连续出现：

```text
virtio_gpu_cmd_get_display_info
virtio_gpu_cmd_res_create_2d res 0x2
virtio_gpu_cmd_res_back_attach res 0x2
virtio_gpu_cmd_set_scanout id 0, res 0x2
virtio_gpu_cmd_res_flush res 0x2
```

该结果证明控制队列不再卡在 `GET_DISPLAY_INFO`，scanout 资源已建立并持续刷新。串口中的详细 GPU 日志在桌面模式前后的阈值控制下可能被隐藏；设备端 trace 是本项验证的权威证据。

## 11. 状态

- Fixed

## 12. 修复记录与阶段边界结论

已修改 `src/drivers/video/core/framebuffer.zig`：不再要求帧缓冲总长为 4KiB 整数倍，直接使用 `fb_config.address` 作为 guest physical address，并按 `u32::MAX` 上限切分 entries。

控制队列响应延迟问题另见 `reports/040-virtio-gpu-dma-uncached-mapping.md`。

阶段边界：

1. **UEFI GOP**：ZBM 菜单与 `winload.efi` 引导阶段。
2. **BootVID**：`ExitBootServices` 后激活帧缓冲 console，输出内核启动日志。
3. **VirtIO-GPU**：桌面首帧渲染前停用 BootVID；屏幕日志阈值调整为 WARNING；VirtIO scanout 作为设备显示路径。

与原始 Windows 7 二进制对照结论：**有偏差，部分实现**。当前代码对齐了启动阶段边界，但没有复刻 Windows 7 完整的 `bootvid.sys`、`win32k.sys`、DWM/WDDM 驱动栈，也没有本条相关的 REA 函数级镜像证据。
