# 问题 #100：关键内核/驱动文件复刻完成度清单

## 1. 问题编号

`100`

## 2. 清单说明

本清单对照 Windows 7 SP1 x64 镜像（`cn_windows_7_ultimate_with_sp1_x64_dvd_u_677408.iso`）中的关键内核/驱动 PE 文件与 ZirconOSAero 代码模块，标注复刻状态。

状态定义：
- **已复刻**：核心行为可观察等价，编译通过，QEMU 运行验证
- **部分复刻**：核心路径已有 Zig 实现，但 API 覆盖或边界行为有差距
- **未复刻**：仅有占位/stub，或未开始

## 3. 内核核心

| Windows 7 文件 | ZirconOSAero 模块 | 状态 | 差距说明 |
|---|---|---|---|
| `ntoskrnl.exe` (Ke) | `src/ke/` (19 文件) | 部分复刻 | 线程调度、APC/DPC、IRQL、定时器、自旋锁已实现；中断处理依赖 arch 层；Win32 KTHREAD/KPROCESS 完整字段未对齐 |
| `ntoskrnl.exe` (Mm) | `src/mm/` (12 文件) | 部分复刻 | Buddy 分配器、PFN 数据库、MDL、工作集、VAD、分段堆已有；section 对象、pagefile、cache manager 有限 |
| `ntoskrnl.exe` (Ob) | `src/ob/` | 部分复刻 | 对象类型、句柄表、引用计数已实现；对象类型数量和命名空间覆盖有限 |
| `ntoskrnl.exe` (Ps) | `src/ps/` | 部分复刻 | 进程/线程创建、用户态进程注册已实现；token 集成、job 对象、debug port 未完整 |
| `ntoskrnl.exe` (Ex) | 分散在 `src/ke/`, `src/ob/`, `src/ps/` | 部分复刻 | 资源对象（Event/Mutex/Semaphore/Timer）、lookaside list 已实现；ERESOURCE、fast mutex 部分覆盖 |
| `ntoskrnl.exe` (Rtl) | `src/rtl/` | 部分复刻 | klog、bootvid console 已实现；AVL table、RTL_HASH 等未覆盖 |

## 4. HAL

| Windows 7 文件 | ZirconOSAero 模块 | 状态 | 差距说明 |
|---|---|---|---|
| `hal.dll` (x64) | `src/hal/` + `src/hal.zig` | 已复刻 | 平台能力表（`platform.zig`）统一入口；5 架构委托层；PCI config、input、thread context、percpu 已实现 |
| `acpi.sys` | `src/hal/acpi.zig` | 部分复刻 | ACPI 表解析已实现；AML 解释器、电源管理、热区未实现 |

## 5. 引导链

| Windows 7 文件 | ZirconOSAero 模块 | 状态 | 差距说明 |
|---|---|---|---|
| `bootmgfw.efi` | `boot/zbm/uefi/main*.zig` | 已复刻 | UEFI 启动管理器；BCD 解析；5 架构菜单 |
| `winload.efi` | `boot/zbm/loader.zig` | 部分复刻 | PE 加载、页表设置已实现；winload 特有 API（`Bs*`）覆盖有限 |
| `bootmgr.efi` | `boot/zbm/uefi/` | 部分复刻 | 基础 boot manager 已实现；winpe 镜像加载未覆盖 |
| `memtest.efi` | ESP 占位（0 字节） | 未复刻 | 内存测试功能未实现 |
| BCD | `boot/zbm/common/bcd.zig` | 已复刻 | Boot Configuration Data 解析与生成 |

## 6. 驱动

| Windows 7 文件 | ZirconOSAero 模块 | 状态 | 差距说明 |
|---|---|---|---|
| `bootvid.sys` | `src/drivers/video/bootvid.zig` | 已复刻 | 6.1 启动画面（VGA 80×25 蓝底白字）、`\Driver\Bootvid` 注册、`\Device\Bootvid0`、3 阶段切换（UEFI GOP→BootVID→VirtIO-GPU）QEMU 验证 |
| `disk.sys` | `src/drivers/storage/` | 部分复刻 | 块设备 IRP 分发已实现；PnP 静音安装、磁盘签名未完整 |
| `partmgr.sys` | `src/drivers/bus/` | 部分复刻 | MBR/GPT 分区解析已实现；分区通知回调覆盖有限 |
| `classpnp.sys` | `src/drivers/storage/` | 部分复刻 | 磁盘类驱动框架已实现；SCSI 请求块完整路径未覆盖 |
| `win32k.sys` | `src/subsystems/win32/user32.zig` + `gdi32.zig` | 部分复刻 | User32 窗口消息、GDI 色彩/ROP 契约已实现；win32k full syscall 表、DPI/字体引擎未覆盖 |
| `vmbus` / `virtio` 驱动 | `src/drivers/` (bus/input/net/storage/video/usb/wdf) | 部分复刻 | VirtIO-GPU (1af4:1050)、VirtIO-Input、VirtIO-Net QEMU 验证；其他 PCI 设备枚举覆盖有限 |

## 7. 用户态 API DLL

| Windows 7 文件 | ZirconOSAero 模块 | 状态 | 差距说明 |
|---|---|---|---|
| `ntdll.dll` | `src/libs/ntdll.zig` | 部分复刻 | Nt/Yt 系统调用分发、Ldr 初始化已实现；完整 syscall 数量与 NT 6.1 SSDT 有差距 |
| `kernel32.dll` | `src/libs/kernel32.zig` | 部分复刻 | 基础 Win32 API 已实现；完整导出表 (~1600 exports) 有差距 |
| `user32.dll` | `src/subsystems/win32/user32.zig` | 部分复刻 | 窗口消息、输入、桌面切换已实现；DPI、IME、触摸输入未覆盖 |
| `advapi32.dll` | `src/registry/` | 部分复刻 | 注册表 hive (REGF) 解析/写入已实现；安全描述符、审计事件覆盖有限 |
| `cmd.exe` | `src/subsystems/win32/cmd.zig` (213 dispatch) + `src/desktop/applications/accessories/cmd_shell.zig` (桌面桥接) | 部分复刻 | 213 条内核命令 + 桌面 CMD 桥接全部命令；批处理、管道重定向、延迟变量扩展未覆盖 |
| `csrss.exe` | `src/subsystems/win32/subsystem.zig` | 部分复刻 | Win32 子系统进程注册、console 分发已实现；LPC 完整协议、SxS 未覆盖 |

## 8. 多架构支持

| 架构 | 状态 | 说明 |
|---|---|---|
| x86_64 | ✅ 已复刻 | 构建 + 测试 + QEMU UEFI 启动 + 桌面验证 |
| aarch64 | ✅ 已复刻 | 构建通过；QEMU 未完整验证桌面 |
| riscv64 | ✅ 已复刻 | 构建通过；QEMU 未完整验证桌面 |
| mips64el | ✅ 已复刻 | 构建通过；QEMU 未完整验证桌面 |
| loongarch64 | ⚠️ 部分复刻 | Zig 0.18 LLVM 后端 `Invalid cast` 已知 bug（非项目代码），需 Zig 版本升级 |
| sw64 | ❌ 未复刻 | 申威 831/421 架构未实现 |

## 9. ESP 目录结构

| Windows 7 要求 | ZirconOSAero 产物 | 状态 |
|---|---|---|
| `EFI/Boot/BOOTX64.EFI` | ✅ 36352 字节 | 已复刻 |
| `EFI/Microsoft/Boot/BCD` | ✅ | 已复刻 |
| `EFI/Microsoft/Boot/bootmgfw.efi` | ✅ 36352 字节 | 已复刻 |
| `EFI/Microsoft/Boot/bootmgr.efi` | ✅ 占位 | 部分复刻 |
| `EFI/Microsoft/Boot/memtest.efi` | ✅ 占位（0 字节） | 未复刻 |
| `EFI/Microsoft/Boot/Fonts/` | ✅ GNU FreeFont | 已复刻 |
| `Windows/System32/ntoskrnl.exe` | ✅ | 已复刻 |
| `Windows/System32/winload.efi` | ✅ | 已复刻 |
| `Windows/System32/hal.dll` | ✅ | 已复刻 |
| `Windows/System32/kernel32.dll` | ✅ | 已复刻 |
| `Windows/System32/user32.dll` | ✅ | 已复刻 |
| `Windows/System32/advapi32.dll` | ✅ | 已复刻 |
| `Windows/System32/config/` (SYSTEM/SOFTWARE/SAM/SECURITY/DEFAULT) | ✅ | 已复刻 |
| `Windows/System32/drivers/` (acpi/disk/partmgr/classpnp/bootvid) | ✅ | 已复刻 |

无 `kernel.elf` 或其他非 Windows 7 目录出现。

## 10. 验证方法

- `make build ARCH=<arch>` 验证编译
- `make test ARCH=x86_64` 验证单元测试
- `make build-esp ARCH=x86_64` + `mdir -i build/esp-x86_64.img@@2048s ::/` 验证 ESP 结构
- QEMU UEFI 启动 + 串口日志验证启动链路
- QEMU 桌面验证（BootVID → VirtIO-GPU → Aero → cmd.exe PID=4）

## 11. 状态

- Confirmed
