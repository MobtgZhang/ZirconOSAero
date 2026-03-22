# ZirconOS 总体架构设计

## 1. 设计定位

**ZirconOS = NT 风格混合微内核 + 用户态子系统 + Zig 实现**

核心设计思想：

- **微内核 + 用户态系统服务**：内核最小化，系统语义在用户态 server/subsystem 中实现
- **NT 风格思路**：面向对象 / 句柄 (Handle) / 命名空间 (Namespace) / 系统服务化
- **Zig 实现**：利用 Zig 的编译期能力与无 libc 依赖，保持可控边界
- **兼容性分阶段**：先 Native + ELF → 再 PE → 再 Win32 子系统 → 最后 WOW64

## 2. 系统分层模型

```
┌──────────────────────────────────────────────┐
│                Applications                   │
│       Win32 Apps  ·  POSIX Apps  ·  Native    │
├──────────────────────────────────────────────┤
│              Subsystems (用户态)               │
│     Win32  ·  POSIX  ·  WOW64  ·  Native     │
├──────────────────────────────────────────────┤
│           System Services (用户态)             │
│  Process Server · Object Manager · I/O Mgr    │
│  Security  ·  Session Manager  ·  Loader      │
├──────────────────────────────────────────────┤
│            Microkernel (内核态)                │
│  Scheduler · IPC · VM · Syscall · Interrupt   │
├──────────────────────────────────────────────┤
│          HAL - Hardware Abstraction           │
│  CPU · APIC · IO Ports · Timer · GDT · IDT   │
├──────────────────────────────────────────────┤
│               Hardware                        │
└──────────────────────────────────────────────┘
```

### 2.1 内核态 (Kernel Mode)

#### Microkernel Core

内核只提供最基础的"机制"，不包含策略：

| 职责 | 说明 |
|------|------|
| 调度 | 线程调度、优先级、时间片 (Round-Robin) |
| 虚拟内存 | 地址空间、页表映射/解映射、权限控制 |
| IPC | LPC 端口、同步 call/reply、消息队列 |
| 中断/异常 | IDT 分发、IRQ 处理、异常上送 |
| 系统调用 | `int 0x80` 分发、稳定 ABI |
| 句柄原语 | 引用/复制/关闭/跨进程转移 |

#### Executive Core

借鉴 NT Executive，在内核态保留部分关键管理器：

| 模块 | 目录 | 职责 |
|------|------|------|
| Object Manager | `src/ob/` | 对象类型系统、命名空间、句柄表 |
| Memory Manager | `src/mm/` | 物理帧分配、虚拟内存、堆 |
| Process Manager | `src/ps/` | 进程/线程对象管理 |
| I/O Manager | `src/io/` | 设备/驱动/IRP 框架 |
| Security | `src/se/` | Token / SID / 访问检查 |

#### HAL (Hardware Abstraction Layer)

| 模块 | 说明 |
|------|------|
| CPU | 段描述符、TSS、控制寄存器 |
| APIC / PIC | 中断控制器 |
| PIT | 可编程间隔定时器 |
| IO Ports | 端口 I/O 操作 |
| Serial | COM1 串口输出 |
| VGA | 文本模式输出 |
| Framebuffer | 图形帧缓冲 |

### 2.2 用户态 (User Mode)

#### System Services

通过 LPC/IPC 与内核通信的用户态系统组件：

| 服务 | 职责 |
|------|------|
| Process Server (PID 1) | 进程/线程创建、终止、查询 |
| Session Manager (SMSS, PID 2) | 会话管理、子系统注册与启动 |
| Object Server | 对象命名空间高层策略 |
| I/O Server | 设备与文件系统策略 |
| Security Server | 权限与访问控制策略 |
| Loader | ELF / PE 映射、重定位、导入解析 |

#### Subsystems

提供应用兼容层 API：

| 子系统 | 说明 |
|--------|------|
| Native | ZirconOS 原生 API |
| Win32 | kernel32 / user32 / gdi32 / ntdll 兼容 |
| POSIX | libc / POSIX API 映射 |
| WOW64 | 32 位 PE thunk + ABI 转换 |

## 3. 对象模型

对象模型是 NT 风格设计的核心，所有内核资源统一对象化管理。

### 3.1 对象头 (Object Header)

每个内核对象都包含统一的对象头：

```
ObjectHeader {
    type_index     对象类型索引
    ref_count      引用计数
    handle_count   句柄计数
    name           对象名称 (可选)
    flags          对象标志
}
```

### 3.2 对象类型

当前已实现的对象类型：

| 类型 | 说明 |
|------|------|
| Process | 进程对象 |
| Thread | 线程对象 |
| Token | 安全令牌 |
| Event | 事件同步对象 |
| Mutex | 互斥量 |
| Semaphore | 信号量 |
| Port | LPC 通信端口 |
| File | 文件对象 |
| Device | 设备对象 |
| Driver | 驱动对象 |
| Directory | 命名空间目录 |
| SymbolicLink | 符号链接 |
| Section | 内存映射段 |

### 3.3 句柄表 (Handle Table)

每个进程拥有独立的句柄表，句柄不直接暴露内核指针：

- `ObCreateObject` — 创建对象
- `ObReferenceObject` — 增加引用
- `ObOpenObjectByName` — 按名称打开对象
- `ObInsertHandle` — 插入句柄
- `ObCloseHandle` — 关闭句柄

### 3.4 命名空间

NT 风格的对象命名空间树：

```
\
├── ObjectTypes/     对象类型注册
├── Devices/         设备对象
├── Sessions/        会话
├── KnownDlls/       已知 DLL 缓存
├── BaseNamedObjects/ 用户态命名对象
└── LPC/             LPC 端口
    ├── PsServer
    ├── ObServer
    ├── IoServer
    ├── SmssServer
    ├── NativeSubsys
    └── Win32Subsys
```

## 4. IPC 设计

微内核系统中 IPC 是最关键的基础设施。

### 4.1 内核原语层

- 消息队列 (message queue)
- 同步 request / reply
- 共享内存段 (shared memory section)
- 事件通知 (event notification)

### 4.2 LPC 端口层

基于 NT LPC (Local Procedure Call) 风格：

| 操作 | 说明 |
|------|------|
| CreatePort | 创建命名端口 |
| ConnectPort | 客户端连接端口 |
| RequestWaitReply | 发送请求并等待回复 |
| Reply | 服务端回复消息 |
| Listen | 监听连接请求 |

消息结构：64 字节数据区，包含 sender、receiver、opcode 和 payload。

## 5. 安全模型

预留 NT 风格安全框架，当前为简化实现：

| 概念 | 说明 |
|------|------|
| Token | 安全令牌，附加在每个进程上 |
| SID | 安全标识符 |
| Access Mask | 访问权限掩码 |
| ACL | 访问控制列表 (简化版) |

在对象打开时执行访问检查，确保句柄权限、进程隔离和服务权限的基础框架。

## 6. 设计原则

| 原则 | 说明 |
|------|------|
| 先机制、后策略 | 内核先做对调度/VM/IPC，再把策略上移到用户态服务 |
| 接口先行 | 新增能力先定义 RPC / syscall / 对象类型接口，再填实现 |
| 可观测性优先 | 保留串口/日志管线，便于定位问题 |
| 渐进兼容 | PE / Win32 / WOW64 按阶段落地，避免一步到位 |
| 可替换实现 | 服务/子系统可重启/替换，崩溃隔离是微内核路线的收益点 |

## 7. 非目标

明确以下不在当前设计范围内，避免项目失控：

- **不做完整 NT 内核复刻**：不追求同 ABI / 同实现细节
- **不把 Win32 语义塞进内核**：窗口/消息/GDI 属于子系统层
- **不追求跑大型应用**：先稳定启动、创建进程、IPC、加载最小用户态程序
- **不做完整 Windows 驱动兼容**
- **不做完整 GDI / DirectX / SMP 优化**
