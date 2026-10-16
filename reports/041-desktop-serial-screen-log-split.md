# 问题 #41：桌面模式阈值误抑制串口全量日志

## 1. 问题编号

`41`

## 2. 问题位置

- 文件路径：`src/rtl/klog.zig`
- 函数/模块：`shouldLog()`、`output()`、`klogEmit()`
- 相关路径：`src/arch.zig` 及各 `src/arch/*/mod.zig` 的 `consoleWriteScreen()`

## 3. 问题描述

桌面模式启用后，`desktop_min_level` 同时作用于串口和屏幕。因此进入桌面后 INFO/DEBUG 日志被全局抑制，串口无法继续提供完整审计输出；这与“屏幕桌面阶段静默、串口始终输出全部日志”的要求不一致。

## 4. 复现路径

1. 启动 x86-64 UEFI QEMU。
2. 等待 `ExitBootServices`、BootVID 启动日志和 DWM 桌面初始化。
3. 修复前，桌面初始化后的 INFO/DEBUG 日志既不会回显屏幕，也不会继续写入串口。

## 5. 影响范围

- 丢失桌面阶段的运行时诊断能力。
- 排查 DWM、VirtIO-GPU、输入、进程调度和用户态服务问题时缺少完整时间线。
- 违反启动/桌面日志边界：串口是调试与审计通道，屏幕仅是用户可见通道。

## 6. 严重程度

- High

## 7. 可能原因

`klog` 只有一个 `output()` 路径，`arch.consoleWrite()` 同时写串口和屏幕；`shouldLog()` 无法表达两个通道不同的过滤策略。

## 8. 权威参考依据

- Windows NT/Win32 的启动与运行诊断一般分为 debugger/serial sink 与显示 sink；本修复按项目目标将 COM/UART 作为全量 sink，屏幕由 BootVID/DWM 管控。
- 本项目 `src/arch/x86_64/mod.zig`、`src/rtl/bootvid_console.zig` 和 `src/kernel/desktop_session.zig` 的源码级行为。
- 本条未使用 REA 对 Windows 7 镜像完成函数级对照；Windows 7 实际有 DbgPrint/KD、Event Log、BSOD、启动动画等多通道机制，当前实现只对齐日志阶段边界，不声称一比一等价。

## 9. 建议修复方案

将 `shouldLog()` 拆分为 `shouldSerialLog()` 和 `shouldScreenLog()`。串口始终写入全部级别；屏幕仅在 BootVID active 且未进入桌面时写入。各架构新增 `consoleWriteScreen()`，避免通过 `consoleWrite()` 造成串口重复输出。

## 10. 验证方法

已执行：

```bash
zig build test
make build ARCH=x86_64
make build ARCH=aarch64
make build ARCH=riscv64
make build ARCH=mips64el
make build-esp ARCH=x86_64
git diff --check
```

已用 QEMU TCG 运行 90 秒。串口持续记录到 25.44 秒的桌面阶段，包含：

```text
DWM: Aero compositor initialized
VirtIO-GPU: cursor queue enabled
Desktop: DWM Aero compositor initialized
Desktop: Rendering aero theme
Desktop: session shell PID=3 UI_TID=1 (dwm.exe)
```

这些 INFO/DEBUG 级日志保留在串口；`consoleWriteScreen()` 在 BootVID 停用后不再向帧缓冲写入。

## 11. 状态

- Fixed

## 12. 与 Windows 7 对照结论

有偏差，部分实现。该修复对齐了项目定义的三阶段显示链路：UEFI GOP、BootVID、桌面正式 GPU。当前仍没有复刻 Windows 7 的完整 Event Log/KD/WER/DWM 日志体系，也没有 REA 函数级镜像证据。
