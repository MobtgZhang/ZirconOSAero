# 问题 #40：VirtIO-GPU DMA 缓冲未按 uncached 映射

## 1. 问题编号

`40`

## 2. 问题位置

- 文件路径：`src/drivers/video/virtio/virtio_gpu_pci.zig`
- 函数/模块：`tryGpuBringup()`、`submitControlRaw()`、`submitCursor()`
- 相关缓冲：`ring_page`、`ring_cursor`、`gpu_cmd_io`、`gpu_attach_blob`、`gpu_scratch_mem`、`gpu_cursor_io`

## 3. 问题描述

VirtIO-Input 队列页已在启用设备前执行 uncached identity remap，而 VirtIO-GPU 的控制环、游标环和 DMA 缓冲未做同样处理。QEMU 中 `GET_DISPLAY_INFO` 能到达设备，但设备不回填 used ring，控制队列提交在 2,000,000 次轮询后超时，导致桌面只能回退到 CPU 合成显示路径。

## 4. 复现路径

1. 使用 Zig 0.18-dev 构建 x86-64 UEFI ESP。
2. 启动 QEMU，附加 `virtio-gpu-pci` 与绑定到该 GPU 的 virtio 输入设备。
3. 启用 `virtio_gpu*` trace。
4. 修复前 trace 显示 `virtio_gpu_cmd_get_display_info`，但没有后续 `RESP_OK`、`RESOURCE_CREATE_2D` 和 `SET_SCANOUT`。

## 5. 影响范围

- 阻止 VirtIO-GPU scanout 建立和桌面正式 GPU 显示路径。
- 桌面回退到 CPU 合成/GOP present，表现为仍然依赖 UEFI GOP 形态。
- 游标队列也会因同类缓存可见性问题无法可靠提交。

## 6. 严重程度

- Critical

## 7. 可能原因

CPU 对 BSS 中的 DMA 共享缓冲使用可缓存映射。设备写入 used ring 或响应缓冲后，CPU 读到 stale cache 数据；控制队列的 used index 因此看起来始终没有变化。项目内已验证的 virtio-input 路径提供了同一根因线索。

## 8. 权威参考依据

- VirtIO v1.2 PCI modern transport 规范：描述符、avail/used ring 是 guest/device 共享内存，需保证内存可见性。
- 本项目 `src/drivers/input/virtio_input_pci.zig` 的 `remapInstQueueDmaUncached()` 源码级对照。
- QEMU `virtio_gpu*` trace 实际行为。
- 本条未使用 REA 对 Windows 7 镜像完成函数级对照；Windows 7 WDDM/VirtIO 驱动栈与本项目当前实现不等价。

## 9. 建议修复方案

在注册队列前，用 `vm.remapIdentityRangeUncached()` 把 GPU DMA 共享缓冲改回 identity、可写、非缓存映射。控制环、游标环、命令 I/O、attach blob、scratch 和 cursor I/O 都应覆盖。随后在 `DRIVER_OK` 前执行 full memory fence。

## 10. 验证方法

已执行：

```bash
zig version
zig build test
make build ARCH=x86_64
make build-esp ARCH=x86_64
git diff --check
```

已用 QEMU TCG 运行 45 秒，并启用 `virtio_gpu*` trace。修复后设备端连续出现 `GET_DISPLAY_INFO`、`RESOURCE_CREATE_2D`、`RESOURCE_ATTACH_BACKING`、`SET_SCANOUT` 和 `RESOURCE_FLUSH`，控制队列不再阻塞在第一条命令。

## 11. 状态

- Fixed

## 12. 与 Windows 7 对照结论

Windows 7 没有 VirtIO-GPU 设备栈，因此不存在“与原始二进制一致”的函数级对照。该修复的兼容性目标是 NT 6.1 的显示驱动加载阶段：UEFI/winload 阶段使用固件扫描输出，内核启动日志走 BootVID，桌面阶段切换到正式显示驱动。当前 VirtIO-GPU 是 QEMU 环境中的 WDDM-like 替代路径，仍不是完整的 NT 6.1 WDDM 一比一复刻。
