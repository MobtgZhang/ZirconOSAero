# ZirconOS 内核实现

本文档描述 ZirconOS 内核各子系统的具体实现细节。

## 1. 源码布局

```
src/
├── main.zig           # 内核入口，Phase 0–12 启动流程
├── arch.zig           # 架构抽象分发
├── arch/              # 架构相关实现
│   ├── x86_64/        #   start.s, boot.zig, paging.zig, idt.zig, syscall.zig, ...
│   ├── aarch64/       #   启动, 分页
│   ├── loongarch64/
│   ├── riscv64/
│   └── mips64el/
├── hal/               # 硬件抽象层
│   ├── x86_64/        #   vga.zig, pic.zig, pit.zig, serial.zig, gdt.zig, ...
│   └── aarch64/       #   gic.zig, timer.zig, pl011.zig
├── ke/                # Kernel Executive
│   ├── scheduler.zig  #   线程调度器
│   ├── timer.zig      #   定时器
│   ├── interrupt.zig  #   中断分发 + syscall 入口
│   └── sync.zig       #   同步原语
├── mm/                # 内存管理
│   ├── frame.zig      #   物理帧分配器
│   ├── vm.zig         #   虚拟内存管理
│   └── heap.zig       #   内核堆
├── ob/                # 对象管理器
│   └── object.zig     #   对象头, 句柄表, 命名空间
├── ps/                # 进程子系统
├── se/                # 安全子系统
│   └── token.zig      #   安全令牌
├── io/                # I/O 管理器
│   └── io.zig         #   设备, 驱动, IRP
├── lpc/               # IPC
│   ├── port.zig       #   LPC 端口
│   └── ipc.zig        #   消息 send/receive
├── fs/                # 文件系统
│   ├── vfs.zig        #   虚拟文件系统
│   ├── fat32.zig      #   FAT32 (C:\)
│   └── ntfs.zig       #   NTFS (D:\)
├── loader/            # 加载器
│   ├── pe.zig         #   PE32/PE32+ 加载
│   └── elf.zig        #   ELF 加载
├── drivers/           # 设备驱动
│   ├── video/         #   VGA, HDMI, Framebuffer, Display, DWM
│   ├── audio/         #   AC97
│   └── input/         #   PS/2 鼠标
├── rtl/               # 运行时库
├── config/            # 配置解析与嵌入式默认 *.conf
└── registry/          # 注册表
```

## 2. 架构支持 (arch/)

通过 `src/arch.zig` 按编译目标选择对应架构实现。

### x86_64 (主要架构)

| 文件 | 职责 |
|------|------|
| `start.s` | 32 位入口 → 建立页表 → 开启 PAE + 长模式 + 分页 → 64 位 → 设置栈/SSE → 调用 `kernel_main` |
| `boot.zig` | 解析 Multiboot2 信息：内存映射、命令行、framebuffer、启动模式与桌面主题 |
| `paging.zig` | 四级页表管理，identity mapping，framebuffer 映射 |
| `idt.zig` | 中断描述符表，256 个向量 |
| `isr_common.s` | 32 个异常 + 16 个 IRQ stub → 统一进入 `isr_common_handler` |
| `syscall_entry.s` | `int 0x80` 入口，寄存器保存/恢复 |
| `syscall.zig` | 系统调用分发表 |

### 系统调用约定 (x86_64)

- 入口：`int 0x80`（向量 128）
- 调用号：`rax`
- 参数：`rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9`

已实现的系统调用：

| 编号 | 名称 | 功能 |
|------|------|------|
| 0 | SYS_IPC_SEND | 发送 IPC 消息 |
| 1 | SYS_IPC_RECEIVE | 接收 IPC 消息 |
| 2 | SYS_CREATE_PROCESS | 创建进程 |
| 3 | SYS_CREATE_THREAD | 创建线程 |
| 4 | SYS_MAP_MEMORY | 映射内存 |
| 5 | SYS_EXIT_PROCESS | 退出进程 |
| 6 | SYS_CLOSE_HANDLE | 关闭句柄 |
| 7 | SYS_GET_PID | 获取进程 ID |
| 8 | SYS_YIELD | 主动让出 CPU |
| 9 | SYS_DEBUG_PRINT | 调试输出 |

## 3. 内存管理 (mm/)

### 3.1 物理帧分配器 (frame.zig)

- **算法**：位图管理可用物理页
- **数据源**：Multiboot2 mmap 获取物理内存布局
- **容量**：最多约 1GB 物理内存
- **页大小**：4KB

### 3.2 虚拟内存 (vm.zig)

| 接口 | 说明 |
|------|------|
| AddressSpace | 进程地址空间抽象 |
| mapPage | 映射虚拟页到物理帧 |
| unmapPage | 解除页映射 |
| MapFlags | 权限标志：writable, user, executable, no_cache |

当前采用 identity mapping 方案，内核与 framebuffer 使用独立映射。

### 3.3 内核堆 (heap.zig)

- **算法**：Bump 分配器
- **大小**：512KB
- **用途**：内核态动态内存分配

## 4. 调度器 (ke/scheduler.zig)

| 特性 | 说明 |
|------|------|
| 算法 | Round-Robin |
| 最大线程数 | 32 |
| 线程栈大小 | 8KB |
| 时钟源 | PIT IRQ0 驱动 tick |
| 线程状态 | ready, running, blocked, terminated |
| 控制 | `scheduling_enabled` 标志可暂停调度 |

## 5. 中断与定时器

### IDT (idt.zig)

256 个中断向量：
- 0–31：CPU 异常（除零、页错误、通用保护等）
- 32–47：硬件 IRQ（PIT、键盘、串口、鼠标等）
- 128：系统调用 (`int 0x80`)

### PIC + PIT

| 组件 | 说明 |
|------|------|
| PIC | 8259A 可编程中断控制器，级联配置 |
| PIT | 8254 定时器，约 100Hz tick 频率 |

### 中断分发链

```
硬件中断 / 异常 / int 0x80
    → IDT 向量
    → ISR stub (isr_common.s)
    → isr_common_handler
    → interrupt.zig 分发
    → 异常处理 / IRQ 处理 / syscall 分发
```

## 6. 对象管理器 (ob/object.zig)

NT 风格的统一对象管理系统。

### 核心数据结构

- **ObjectHeader**：对象头，包含类型、引用计数、句柄计数、名称
- **HandleTable**：每进程句柄表，句柄 → (对象指针, 授予权限, 标志)
- **Namespace**：对象命名空间树，支持目录和符号链接
- **Waitable**：可等待对象接口

### 支持的操作

| 操作 | 说明 |
|------|------|
| 创建 | 分配对象头 + 类型特定体 |
| 引用 | 增加/减少引用计数 |
| 命名 | 在命名空间中注册 |
| 句柄化 | 插入进程句柄表，返回句柄值 |
| 等待 | 同步等待对象信号 |
| 关闭 | 减少句柄计数，必要时销毁 |

## 7. I/O 管理器 (io/io.zig)

NT 风格的 I/O 请求包 (IRP) 模型。

### 核心对象

| 对象 | 说明 |
|------|------|
| DriverObject | 驱动对象，包含入口点和分发表 |
| DeviceObject | 设备对象，挂载到驱动上 |
| Irp | I/O 请求包，描述一次 I/O 操作 |

### IRP 主功能码

create, close, read, write, ioctl, query_info 等。

### 设备类型

console, serial, keyboard, disk, framebuffer, mouse, audio 等。

### I/O 路径

```
用户态 API 调用
  → I/O Manager
  → 构建 IRP
  → 设备栈分发
  → Driver Dispatch 处理
  → 完成 IRP，返回结果
```

## 8. 文件系统 (fs/)

### VFS (vfs.zig)

虚拟文件系统层提供统一的文件操作接口：

| 概念 | 说明 |
|------|------|
| MountPoint | 挂载点管理 |
| FileObject | 文件对象 |
| FsOps | 文件系统操作接口 |

### FAT32 (fat32.zig)

- 挂载为 `C:\`
- 支持：文件创建、读写、目录遍历、删除

### NTFS (ntfs.zig)

- 挂载为 `D:\`
- 支持：MFT 解析、文件/目录操作

## 9. 加载器 (loader/)

### PE 加载器 (pe.zig)

| 功能 | 说明 |
|------|------|
| PE32+ | 64 位 PE 头解析、节映射 |
| PE32 | 32 位 PE 支持 (WOW64) |
| DLL 加载 | 导入表解析、绑定 |
| 重定位 | 基址重定位修正 |
| PEB/TEB | 进程/线程环境块构建 |

### ELF 加载器 (elf.zig)

- 多架构 ELF 支持
- ELF64 头解析、段加载
- 共享对象处理

## 10. 设备驱动 (drivers/)

### 视频驱动 (drivers/video/)

| 驱动 | 说明 |
|------|------|
| vga.zig | 文本模式 VGA 输出 |
| hdmi.zig | HDMI 显示驱动 |
| framebuffer.zig | 图形 framebuffer |
| display.zig | 桌面显示管理器，支持多种 Windows 风格主题 |
| dwm.zig | Desktop Window Manager 合成器 |

支持的桌面主题：Classic、Luna、Aero、Modern、Fluent、SunValley

**桌面鼠标与合成帧（`main.zig` + `display.zig`）**

- IRQ12 在 `mouse.zig` 中更新绝对坐标并设置 `cursor_moved`；事件同时入队供按键/滚轮处理。
- 主循环除消费 `popEvent()` 外，必须在 **`hasCursorMoved()` 为真时仍调用 `renderDesktopFrame()`**：否则队列溢出时坐标已更新但无事件，指针不重绘。
- `renderDesktopFrame()` 在一帧内 **排空** `isInterpolating()` 的 PS/2 子步插值，避免仅依赖多次定时器唤醒才能完成插值。

### 音频驱动 (drivers/audio/)

| 驱动 | 说明 |
|------|------|
| ac97.zig | AC97 音频控制器驱动 |
| audio.zig | 音频事件系统（如启动音） |

### 输入驱动 (drivers/input/)

| 驱动 | 说明 |
|------|------|
| mouse.zig | PS/2 鼠标驱动 (x86_64) |

## 11. 同步原语 (ke/sync.zig)

| 原语 | 说明 |
|------|------|
| SpinLock | 自旋锁 |
| Event | 事件对象 (手动/自动重置) |
| Mutex | 互斥量 |
| Semaphore | 信号量 (带计数) |

## 12. 注册表 (registry/)

简化版的 Windows 注册表实现，提供键值对存储。
