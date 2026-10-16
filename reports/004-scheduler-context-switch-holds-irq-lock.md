# 问题 #4：调度器上下文切换在持有调度 IRQ 锁时执行

## 1. 问题编号

`4`

## 2. 问题位置

- 文件路径：`src/ke/scheduler.zig`
- 函数/模块：`tick()`、`performLoongArchContextSwitch()`、`performRiscvContextSwitch()`、`performAarch64ContextSwitch()`、`performMipsContextSwitch()`、`performX86_64ContextSwitch()`
- 行号或代码片段：`tick()` 先执行 `sched_irq_lock.lock()`，随后在两个切换分支内直接调用上下文切换函数；`performX86_64ContextSwitch()` 调用的 `x86_64_switch_context` 为 `noreturn`。

## 3. 问题描述

调度节拍在持有 `sched_irq_lock` 的情况下切换线程栈。由于上下文切换会离开当前调用栈且 `x86_64` 路径不会返回，原调用侧的 `defer sched_irq_lock.unlock()` 不会执行。锁会被永久留在持有状态，后续任何需要该锁的调度入口都会自旋等待。

## 4. 复现路径

在启用抢占或多线程后，让 `tick()` 选择一个与当前线程不同的就绪线程并进入上下文切换。第一次成功切换后，当前 CPU 的调度锁仍处于持有状态。下一次定时器节拍、线程入队或唤醒路径尝试获取 `sched_irq_lock` 时会阻塞。

## 5. 影响范围

- 导致调度器死锁，后续线程无法被抢占或唤醒。
- 影响全部上下文切换架构路径，包括 x86-64、AArch64、LoongArch64、RISC-V 64 与 MIPS64EL。
- 定时器、DPC、等待队列和线程创建等依赖调度锁的功能都会受到连锁影响。

## 6. 严重程度

- Critical

## 7. 可能原因

上下文切换被视作普通函数返回路径处理，但实际切换会改变控制流和栈。`defer` 的生命周期绑定在当前栈帧上，无法跨越上下文切换释放锁。

## 8. 权威参考依据

- 项目源码：`src/ke/scheduler.zig` 的 `tick()` 与各 `perform*ContextSwitch()`；`src/ke/spinlock.zig` 的 `IrqSpinLock` 语义。
- 项目源码：`src/arch/x86_64/thread_switch.zig` 声明 `x86_64_switch_context` 为 `noreturn`。
- 本问题由代码控制流与锁生命周期审计确认，未引用 REA 对 Windows 7 镜像的二进制分析结论，也未将 `/home/mobtgzhang/api.json` 作为行为依据。
- 本问题不涉及复制 Windows 7 内核代码或资源。

## 9. 建议修复方案

在真正进入上下文切换前释放调度锁，并确保释放后不立即重新启用中断，避免同一定时器路径在切换前重入。上下文切换返回到原线程时，再恢复进入锁前的中断状态。该修复应保持目标线程通过后续调度入口重新获得锁，同时避免双重解锁。

## 10. 验证方法

- 使用 `zig build -Darch=x86_64` 确认构建通过。
- 运行项目现有调度相关测试，确认线程创建、唤醒、抢占与让出路径可继续推进。
- 在 QEMU 中运行内核，观察定时器节拍后调度器不再停滞。
- 后续可结合 REA 对 `ntoskrnl.exe` 中调度相关导出符号的行为进行对照，但本报告的结论不依赖该对照。

## 11. 状态

- Fixed

## 12. 修复说明

新增 `IrqSpinLock.unlockKeepingInterruptsDisabled()`，在进入上下文切换前释放调度锁但保持中断关闭。`tick()` 改用 `performContextSwitchLocked()` 统一各架构切换入口，并记录锁已为切换释放，避免原线程恢复后再次解锁。当原线程恢复并从切换函数返回时，按进入锁前保存的中断状态恢复中断。`zig build -Darch=x86_64`、config 与 boot 回归测试均通过；QEMU 运行时验证仍需后续执行。
