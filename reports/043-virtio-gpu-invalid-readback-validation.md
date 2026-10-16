# 问题 #43：VirtIO-GPU 无效“往返读回”校验

## 1. 问题编号

`43`

## 2. 问题位置

- 文件路径：`src/drivers/video/virtio/virtio_gpu_pci.zig`
- 函数/模块：`compositorTryRoundTripFramebufferRect`
- 行号或代码片段：函数连续两次发送 `TRANSFER_TO_HOST_2D` 并比较 guest RAM。

## 3. 问题描述

VirtIO-GPU 2D 资源没有设备到 guest 的读回命令；连续发送 `TRANSFER_TO_HOST_2D` 只会把 guest backing 再次上传设备，无法形成真正的读回路径。清空 guest RAM 后比较 guest RAM 的做法会误报失败。

## 4. 复现路径

桌面初始化时执行 scratch 往返校验，函数保存 guest RAM、清空后再次上传，最后比较已清空的 guest RAM 与旧保存值。

## 5. 影响范围

可能产生误报 WARNING 日志，并使调用方错误怀疑桌面 GPU 后端不可用。

## 6. 严重程度

Medium

## 7. 可能原因

把单向的 `TRANSFER_TO_HOST_2D` 误当作双向读回命令。

## 8. 权威参考依据

VirtIO-GPU 2D 命令序列为 `RESOURCE_CREATE_2D`、`ATTACH_BACKING`、`TRANSFER_TO_HOST_2D`、`SET_SCANOUT`、`RESOURCE_FLUSH`；没有对应的 2D device-to-host transfer 读回命令。

## 9. 建议修复方案

移除无效读回比较函数和调用点。设备能力仍由 `tryGpuScratch2dValidate()` 的单向传输与响应码验证。

## 10. 验证方法

QEMU x86_64 串口已确认 `SET_SCANOUT + guest-RAM backing (flip + RESOURCE_FLUSH)`，不再出现无效 round-trip 失败日志。

## 11. 状态

Fixed
