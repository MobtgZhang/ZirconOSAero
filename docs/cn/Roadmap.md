# ZirconOS 开发路线图

## 1. 设计目标分层

### Level 1 — 内核可用

基础微内核功能，使系统能够稳定启动和运行：

- x86_64 启动 (BIOS + UEFI)
- 基本虚拟内存与分页
- 中断/时钟
- 线程调度器
- IPC 通信
- 用户态进程
- 系统调用

### Level 2 — NT 风格内核模型

建立区别于普通 hobby OS 的核心架构：

- Object Manager + Handle Table
- Process / Thread / Token / Port 对象模型
- LPC 风格 IPC
- IRP 风格 I/O 框架
- Session / Subsystem 架构
- 安全框架 (Token / SID / ACL)

### Level 3 — Win32 兼容

在稳定内核之上构建兼容层：

- PE Loader (PE32 + PE32+)
- ntdll (Native API)
- kernel32 基础子集
- csrss 风格子系统服务器
- user32 / gdi32
- WOW64
- 双 Shell (CMD + PowerShell)

## 2. 里程碑 (Phase 0–11)

### Phase 0 — 工具链与基础设施 ✅

- Zig 交叉编译环境
- QEMU 调试环境
- 串口日志
- 构建系统 (build.zig / Makefile / run.sh)

### Phase 1 — Boot + Early Kernel ✅

- GRUB Multiboot2 启动
- UEFI 启动应用
- GDT / TSS 初始化
- 物理内存发现与帧分配器
- 内核堆 (Bump allocator)
- VGA 文本输出
- 串口输出

### Phase 2 — 中断 / 定时器 / 调度 ✅

- IDT (256 向量)
- PIC + PIT 定时器 (~100Hz)
- Round-Robin 线程调度器
- 键盘/鼠标驱动
- 基础同步原语 (SpinLock, Event, Mutex, Semaphore)

### Phase 3 — 虚拟内存 ✅

- 四级页表
- Identity mapping
- Framebuffer 映射
- 用户/内核地址空间分离
- 页表切换

### Phase 4 — 对象 / 句柄 / 进程核心 ✅

- Object Manager (对象头、类型表、命名空间)
- Handle Table (每进程句柄表)
- Process / Thread 对象
- Security Token
- 可等待对象

### Phase 5 — IPC + 系统服务 ✅

- LPC Port (消息端口)
- 同步 Request / Reply
- Process Server (PID 1)
- Session Manager / SMSS (PID 2)
- 系统 LPC 端口注册

### Phase 6 — I/O + 文件系统 + 驱动 ✅

- I/O Manager (DriverObject / DeviceObject / IRP)
- VFS (虚拟文件系统)
- FAT32 文件系统 (C:\)
- NTFS 文件系统 (D:\)
- 注册表
- 视频/音频/输入驱动

### Phase 7 — 加载器 ✅

- ELF64 加载器
- PE32+ (64 位) 加载器
- PE32 (32 位) 加载器
- DLL 加载与导入解析
- 基址重定位

### Phase 8 — 用户态基础 ✅

- ntdll (Native API 完整实现)
- kernel32 (Win32 Base API)
- 控制台运行时
- CMD 命令提示符
- PowerShell

### Phase 9 — Win32 子系统 ✅

- csrss 子系统服务器
- Win32 应用执行引擎
- PE 加载 + DLL 绑定
- 进程生命周期管理

### Phase 10 — 图形子系统 ✅

- user32 (窗口管理 / 消息队列 / 窗口类 / 输入处理)
- gdi32 (设备上下文 / 绘图原语 / 字体 / 位图)
- GUI 分发
- 桌面主题框架 (Classic / Luna / Aero / Modern / Fluent / SunValley)

### Phase 11 — WOW64 + 音频 ✅

- WOW64 (PE32 加载 / syscall thunking / 32 位 PEB-TEB)
- AC97 音频驱动
- 音频事件系统

## 3. 后续规划

| 方向 | 说明 | 优先级 |
|------|------|--------|
| POSIX 子系统 | libc / POSIX API 映射 | 中 |
| SMP 支持 | 多核调度 (APIC / IOAPIC) | 中 |
| 网络栈 | TCP/IP、Socket API | 中 |
| 真正的进程隔离 | 用户态/内核态地址空间完全分离 | 高 |
| 服务用户态化 | Object/IO/Security Server 迁移到独立进程 | 高 |
| 磁盘驱动 | AHCI / NVMe 存储驱动 | 中 |
| ACPI | 高级电源管理 | 低 |
| 更多架构支持 | aarch64 / riscv64 完善 | 低 |

## 4. 设计原则

| 原则 | 说明 |
|------|------|
| 先机制、后策略 | 内核做好基础机制，策略上移到用户态 |
| 先 Native、后兼容 | 先稳定原生 API，再做 Win32 / POSIX |
| 先 Console、后 GUI | 先命令行能用，再做图形界面 |
| 先 PE32+、后 WOW64 | 先 64 位稳定，再做 32 位兼容 |
| 接口先行 | 先定义清晰的接口，再填充实现 |

## 5. 风险分析

| 风险 | 影响 | 应对策略 |
|------|------|----------|
| 对象模型设计不当 | API / I/O / 权限 / 同步全面混乱 | 优先设计并稳定对象模型 |
| 微内核过小 | 所有策略跨 IPC，性能和调试困难 | 采用混合微内核，保留 Executive 核心 |
| 过早追求 GUI / 兼容 | 在 user32/gdi32/wow64 中陷入泥潭 | 严格按阶段推进 |
| 缺少稳定的 Native API | Win32 层没有坚实基础 | 先做好 ntdll，再做 kernel32 |
| 项目范围膨胀 | 功能过多，无法收敛 | 明确 v1.0 边界，控制非目标 |
