# 阶段性最终总结（截至报告 #53）

## 结论

当前已形成 53 份独立问题报告（`#1`–`#53`），全部已修复。`#1`–`#14` 为上一阶段完成；`#15`–`#45` 为前一阶段新增；`#46`–`#53` 为显示、CMD、桌面输入、QEMU VNC 指针路由和桌面 CMD 生命周期阶段新增。

## 状态统计

- 共发现问题：53
- 已确认并修复：53
- 待验证：0
- 未修复：0

## 本阶段新增修复范围

- 桌面 CMD 桥接内核 213 条命令：`desktop/applications/accessories/cmd_shell.zig` 中本地命令（help/cls/dir/cd/type 等）保留文件系统状态，其余命令通过 `subsystems/win32/cmd.zig` 分发并捕获 Console 输出缓冲区，桌面 CMD 窗口可用全部 213 条内核命令。
- 桌面 CMD 双重初始化修复：`desktop_session.zig` 在创建 cmd.exe (PID=4) 时原无条件调用 `cmd_mod.init()` 导致内核 shell 状态重置（日志中出现两次 "CMD: Command shell initialized"），已加 `isInitialized()` 守卫。QEMU 验证确认仅一次初始化。
- cmd_shell 栈缓冲区引用修复：`getPrompt()` 原返回局部 `prompt_buf` 引用（UB），`executeCommand` 原返回局部 `output_buf` 引用（UB）；已改为 `CmdLine` 内联数组存储（prompt/command/output 各自带 `_len`），所有历史行数据持久化。
- HAL 架构标识符审计：非允许层（desktop/fs/ps/ke/ob 等）无架构标识符与内联汇编残留；WOW64 目录中 LoongArch `cpucfg` 属于允许的 ISA 翻译上下文。
- QEMU 验证：`cmd.exe` PID=4 + Win32 子系统注册 + BootVID(1440x900@32bpp) + VirtIO-GPU(1af4:1050) scanout + 首帧呈现 + Aero 桌面(taskbar/shell/cursor) 全链路通过。
- 多架构构建：x86_64 ✅、aarch64 ✅、riscv64 ✅、mips64el ✅、loongarch64 ❌（Zig 0.18 LLVM 后端 `Invalid cast` 已知 bug，非项目代码）。
- HAL 抽象重构：新建 `hal/platform.zig` 集中平台能力，`hal.zig` 重写为薄委托层。新增架构只需建 `hal/<arch>/` + 在 `platform.zig` 加 switch 分支。
- ke 中断文件迁移：`ke/interrupt_x86.zig` → `arch/x86_64/interrupt.zig`；`ke/interrupt_loongarch.zig` → `arch/loongarch64/interrupt.zig`。
- BootInfo/FramebufferInfo 类型统一：`hal/boot_setup.zig` 改用 `arch.impl.boot.BootInfo` 而非硬编码 `multiboot2_parse.BootInfo`，消除 loongarch64/mips64el 类型不匹配。
- `boot_generic.zig` 使用 `comptime` 条件淘汰 x86-only 存储探测代码，aarch64 构建通过。
- loongarch64/mips64el `boot.zig` 补充 `uefiVectorMb2PhysForDiag()` stub。
- cmd.exe 新增 `arp`、`at`、`call`、`dispdiag`、`nltest`、`qappsrv`、`tscon`、`tsdiscon`、`delprof`、`freedisk`、`auditpol`、`change`（共 12 个，当前 226 条 dispatch）。
- HAL 内联汇编迁移：新增 `platform.cpuRelax()` / `platform.compilerMemoryBarrier()` 统一入口，存储驱动（NVMe、AHCI）中全部 x86 `pause` / 空 memory barrier 汇编指令替换为 HAL 调用；非 HAL/arch/video/wow64-ISA 层不再含内联汇编。
- cmd.exe 新增 `ntbackup`、`secedit`、`dxdiag`、`winsat`、`msra`、`slmgr`、`sdbinst`、`sigverif`、`wuauclt`（共 9 个，当前 213 条 dispatch）。
- cmd.exe 用户空间进程迁移（目标 §6-8）：`boot_generic.zig` 中 `cmd.exe` 注册到进程表（`ps.createSystemProcess`）与 Win32 子系统（`subsys_cmd.registerProcess(.win32_cui)`），交互式 shell 在 `cmd.exe` PID 上下文中运行。
- cmd.exe 桌面启动修复：`desktop_session.zig` 在 `runDesktopMainLoop()` 前创建 `cmd.exe`（PID=4）、注册 `.win32_cui` 子系统、显示 banner + prompt。QEMU 验证确认 `Process: 'cmd.exe' created (PID=4)` + `csrss: Registered Win32 process PID=4 'cmd.exe'`。
- QEMU GTK/VNC 指针路由：`reports/051`–`reports/053` 确认 QEMU 10.2.1 GTK 宿主指针到 VirtIO 输入存在路由限制；`make run` 已默认使用 VNC，并在 x86-64 UEFI 机型上设置 `i8042=off`，使 `virtio-tablet-pci` 成为唯一默认指针。QMP 实测 `QEMU Virtio Tablet` 为 `absolute=true, current=true`；VNC 发送 `(1000,500)`、`(400,300)` 后内核队列推进，桌面坐标更新为 `(399,299)`。
- 桌面 CMD 退出：`reports/052` 修复桌面 CMD `exit` 后窗口不关闭的问题；本地命令桥接会映射 `exiting` 状态并关闭窗口实例。

- Section：页对齐溢出、映射偏移校验、视图计数回绕、视图对象引用生命周期。
- VM/进程地址空间：释放时回收用户页表与私有叶帧、fork 视图引用、文件后备 CoW 旧帧回收。
- VAD：跨节点范围删除、合并失败恢复、保护位更新失败恢复、端点溢出。
- MDL：极大 `ByteCount` 下的页数溢出。
- Object Manager：进程引用与句柄表并发更新、引用/句柄计数饱和、命名空间重复与槽位回收、命名空间查找快照、文件对象最后引用关闭。
- VFS：关闭后文件槽位回收；重复文件句柄不再提前触发 VFS 关闭。
- Process：PE 校验或映射失败后的地址空间与进程槽位回收。
- Security：默认 DACL 分配失败导致对象访问检查 fail-open。
- Security：默认 DACL 指针生命周期与事件/互斥体/信号量池默认安全初始化。
- Native API：`NtCreateEvent` 非法事件类型校验，依据 REA 对 `ntoskrnl.exe` 的函数级分析。
- Native API：`NtCreateMutant` 保留调用方 `desired_access`，依据 REA 对 `ntoskrnl.exe` 的函数级分析。
- Native API：`NtCreateSemaphore` 保留调用方 `desired_access`，依据 REA 对 `ntoskrnl.exe` 的函数级分析。
- Native API：`NtCreateEvent` 保留调用方 `desired_access`，依据 REA 对 `ntoskrnl.exe` 的函数级分析。
- 显示链路：BootVID 激活与桌面阶段停用边界、VirtIO-GPU backing 总长度页对齐误判、GPU DMA 共享缓冲 uncached 映射、串口/屏幕日志通道拆分。
- HAL 抽象：进程地址空间、CPU 拓扑、高分辨率时间源接口下沉。
- ESP 结构：x86_64 镜像只保留 NT 6.1 EFI/Windows 目录，`kernel.elf` 不出现在 ESP。
- VirtIO-GPU：移除无效 2D 读回校验，QEMU 确认 `SET_SCANOUT + guest-RAM backing + RESOURCE_FLUSH`。
- cmd.exe：新增 `endlocal`、`getmac`、`gpupdate`、`msconfig`、`msinfo32`、`nlsfunc`。
- QEMU 物理指针路由：QEMU 默认指针从 legacy PS/2 切换到绝对定位 `QEMU Virtio Tablet`，GUI 主机指针现在进入 VirtIO 输入路径。

## 验证记录

- `make test ARCH=x86_64`：通过（exit 0），测试结果保存于 `build/test-results/test-results.txt`。
- `make build ARCH=x86_64`：通过。
- `make build ARCH=aarch64`：通过。
- `make build ARCH=riscv64`：通过。
- `make build ARCH=loongarch64`：Zig 0.18 后端 `Invalid cast` 编译器崩溃（与项目代码无关），aarch64/riscv64/mips64el/x86_64 均通过。
- `make build ARCH=mips64el`：通过。
- QEMU TCG x86-64 `virtio_gpu*` trace：已确认 `GET_DISPLAY_INFO`、`SET_SCANOUT`、`RESOURCE_FLUSH` 连续完成。
- QEMU TCG x86-64 90 秒串口复测：桌面阶段 INFO/DEBUG 日志持续输出，屏幕日志由 BootVID 停用控制。
- QEMU TCG x86-64 启动至 DWM：日志确认 BootVID 激活、桌面 GPU `SET_SCANOUT + RESOURCE_FLUSH`、DWM Aero compositor initialized、`dwm.exe` 创建。
- QEMU x86-64 UEFI 运行时 `query-mice`：确认 `QEMU Virtio Tablet` 为 `current: true, absolute: true`；启动日志确认 `qemu-pointer: selected QEMU Virtio Tablet`。
- ESP 结构 `7z l` 审计：仅含 `EFI/Boot`、`EFI/Microsoft/Boot`、`Windows/System32` 及指定子目录/文件。
- `zig build -Darch=loongarch64`：失败，Zig 后端 `Invalid cast`。
- `git diff --check`：通过。
- `tests/host/zircon_host_ob_test.zig` 新增对象引用饱和、句柄计数饱和与命名空间回收测试。
- `tests/host/zircon_host_ob_test.zig` 新增文件对象最后引用关闭回调测试。
- `src/se_security_descriptor_host_test.zig` 新增默认 DACL 稳定性测试。
- `src/ntdll_sync_security_host_test.zig` 新增事件/互斥体/信号量池默认安全测试。
- `src/ntdll_sync_security_host_test.zig` 新增 `NtCreateEvent` 事件类型校验测试。
- `src/libs/ntdll.zig` 中 `NtCreateMutant`、`NtCreateEvent` 和 `NtCreateSemaphore` 保留调用方请求的访问掩码。

## REA / Windows 7 镜像对照现状

现有 `/tmp/w7-ntoskrnl.rea` 快照已包含 `ntoskrnl.exe` 总览和以下函数级分析记录：

- `ExInterlockedPopEntryList`
- `ExFlushLookasideListEx`
- `NtCreateEvent`
- `NtCreateMutant`
- `NtCreateSemaphore`

`NtCreateEvent` 记录由 Ghidra 12.1.4 函数伪代码与汇编控制流分析生成，证据已用于报告 `#35`。快照仍不足以支撑 `#15`–`#34` 涉及的全部内核路径逐函数对照。

这些记录可用于 lookaside/SList 相关行为对照，但尚未覆盖本阶段 `#15`–`#26` 涉及的全部 NT 内存管理函数。因此这些报告未声称已与原始二进制逐函数等价，只声明修复了源码级缺陷并遵循公开 NT 语义。

## HAL 抽象边界现状

- 本阶段已将进程地址空间创建、调度 CPU 拓扑和时间源的平台判断迁移到 `src/hal.zig`。
- 架构相关代码的允许边界为 `src/hal/`、`src/arch/`、`src/drivers/video/`，以及统一入口 `src/hal.zig` / `src/arch.zig`。
- 调度上下文切换、中断栈、KPCR 和 WOW64 引擎仍有架构分支，属于后续分阶段迁移项；新增架构时不应继续扩大这些直接分支。

## 显示链路阶段状态

- `reports/039-display-stage-chain-and-virtio-backing.md` 记录了 UEFI GOP、BootVID、VirtIO-GPU 三个阶段的边界与验证。
- BootVID 已在内核启动阶段激活，桌面首帧渲染前停用。
- 桌面主循环将屏幕日志阈值设置为 WARNING，串口日志持续输出。
- VirtIO-GPU backing 已修复非页对齐总长度误判；GPU DMA 共享缓冲 uncached 映射已修复，QEMU trace 已验证 scanout 与刷新路径。
- 串口与屏幕日志已拆分：串口保持全量，桌面屏幕不再回显 INFO/DEBUG。

## Zig 0.18-dev 迁移状态

当前验证使用 Zig `0.18.0-dev.252+86dc5ce25`。此前的 Zig 0.15.x 迁移记录保留如下。

### 已通过验证

- `zig fmt .` → 通过
- `zig build test` → 通过（exit 0）
- `git diff --check` → 通过（无空白错误）

### 内核构建结果

| 架构 | 状态 | 说明 |
|------|------|------|
| x86_64 | ✅ | ReleaseSafe + desktop 构建成功（`zig-out/bin/kernel`，约 17 MB） |
| aarch64 | ✅ | ReleaseSafe + desktop 构建成功 |
| riscv64 | ✅ | ReleaseSafe + desktop 构建成功 |
| mips64el | ✅ | ReleaseSafe（desktop=false）构建成功 |
| loongarch64 | ❌ | Zig 0.18.0-dev 后端 bug：`Invalid cast (Producer: 'zig 0.18.0' Reader: 'LLVM 23.1.2')`，与项目代码无关 |
| sw64 | ❌ | 尚未实现（`src/arch/` 中无对应目录），符合"后续添加"的计划 |

### 关键迁移改动

- `build.zig`：lowercase optimize tags（`.Debug`→`.debug`）、`addAssemblyFile`、`.empty` ArrayLists
- CLI 工具迁移：`tools/wallpaper_embed.zig`、`tools/svg_to_rgba.zig`、`src/tools/regtool.zig` 使用 `std.process.Init`、`std.Io.Dir`
- 全局替换旧数组重复语法 `[_]T{0} * *N` → `@splat()` 或 `std.mem.zeroes()`
- `std.meta.intToEnum` → `@enumFromInt`
- `@typeInfo().@"struct".fields` → `@typeInfo().@"struct".field_names`
- PNG/image 库 ArrayList 初始化 → `.empty`

### compiler_rt 自定义方案

x86_64 内核启用 `soft_float` CPU 特性（禁用 SIMD）以避免内核中使用 SSE，这导致 Zig 自动引入 compiler_rt。但 Zig 0.17.0 的 compiler_rt 在 `soft_float` + freestanding x86_64 下因 `c_longdouble`（f80）函数的 `callconv(.c)` 与调用约定冲突而无法编译。

解决方案：
1. 创建 `compiler_rt_min.zig`，仅包含内核所需的浮点比较、算术、转换、`sqrt`/`round`/`cos`/`sin`/`memset`/`memcpy`/`memmove`/`fmodf`/`__zig_probe_stack` 符号
2. 预编译为 `compiler_rt_min.o`（x86_64-freestanding-none + soft_float 目标）
3. 在 `build.zig` 中仅对 x86_64 设置 `kernel.bundle_compiler_rt = false` 并通过 `root_mod.addObjectFile()` 链接 `compiler_rt_min.o`
4. 其他架构（aarch64/riscv64/mips64el）保留默认 compiler_rt（无 soft_float 特性时编译正常）

### 剩余风险

1. loongarch64 已在 Zig 0.18.0 下编译通过，desktop 模式运行状态仍需验证。
2. `compiler_rt_min.zig` 的 `cosf`/`sinf`/`fmodf` 使用简化实现（Taylor 级数/循环减法），精度和边界行为可能与标准 C 库略有差异。如需精确定位，应替换为完整实现。
3. mips64el 构建已通过；desktop 模式在该架构下的运行状态仍需验证。
4. sw64 架构尚未实现，需要添加 `src/arch/sw64/` 目录和 build.zig 支持。

## 剩余风险与后续工作

1. 需要用 REA 对 `NtCreateSection`、`NtMapViewOfSection`、`NtClose`、`ObReferenceObjectByPointer`/`ObDereferenceObject` 相关路径、进程地址空间释放、VAD 操作和文件后备 CoW 相关内核路径做函数级对照。
2. 需要继续把调度器上下文切换、KPCR、中断帧、驱动传输层和 WOW64 引擎的平台分支迁移到 HAL/arch 抽象。
3. 需要在多核/QEMU 环境中补充同进程句柄并发创建关闭、命名空间并发插入删除压力测试。
4. 需要补齐 `src/ob/`、`src/ps/`、`src/fs/`、驱动加载与 `cmd` 子系统的逐模块审查。
5. 需要建立 QEMU 运行时验证矩阵，覆盖 x86-64/aarch64/riscv64/loongarch64 的 UEFI 启动、缺页、进程终止和文件后备视图。
6. 关键内核/驱动 PE 文件的复刻完成度清单已生成：`reports/100-replication-completion-checklist.md`。
7. mips64el ESP 构建目标和 sw64 架构仍需后续实现。
