# ZirconOSAero 总体架构设计

## 1. 设计定位

**ZirconOSAero = NT 6.1 目标混合微内核 + 用户态子系统 + Zig 实现**

核心设计思想：

- **混合微内核 + 内核内 Executive（当前落地）**：调度、虚拟内存、IPC、系统调用等机制与 **Object/MM/PS/IO/Security、加载器** 等管理器**目前均在内核**（`src/ob/`、`src/mm/`、`src/ps/`、`src/io/`、`src/se/`、`src/loader/` 等）；**独立用户态服务**当前主要是 **Process Server** 与 **SMSS**。进一步用户态拆分见 [Servers.md](Servers.md)、[LPC_USER_SERVERS_CONTRACT.md](LPC_USER_SERVERS_CONTRACT.md)。
- **NT 风格思路**：面向对象 / 句柄 (Handle) / 命名空间 (Namespace) / 系统服务化
- **Zig 实现**：利用 Zig 的编译期能力与无 libc 依赖，保持可控边界
- **兼容性分阶段**：先 Native + ELF → 再 PE → 再 Win32 子系统 → 最后 WOW64

## 2. 系统分层模型

**易错点**：旧图常把 **Object Manager / I/O Manager / Security / Loader** 画在「用户态服务」层；在本仓库 **当前代码** 中它们属于 **内核 Executive**（见 §2.1）。下图按 **`src/` 现状** 绘制；§2.2 表中标出 **计划拆分**。

### 2.0 当前落地（与 `src/` 一致）

```
┌──────────────────────────────────────────────┐
│                Applications                   │
│       Win32  ·  POSIX（规划） · Native       │
├──────────────────────────────────────────────┤
│        Subsystems（用户态，部分实现）          │
│     Win32  ·  WOW64  ·  Native（ntdll 等）    │
├──────────────────────────────────────────────┤
│     用户态服务（当前仅下列独立进程）            │
│     Process Server (PID 1) · SMSS (PID 2)    │
├──────────────────────────────────────────────┤
│                  内核                         │
│  微内核：调度 · VM · LPC · 系统调用 ·          │
│         中断 / 同步 / 定时器                   │
│  Executive：OB · MM · PS · IO · Security     │
│            文件系统/VFS · Loader（PE/ELF）     │
├──────────────────────────────────────────────┤
│          HAL（CPU、APIC/PIC、定时器等）        │
├──────────────────────────────────────────────┤
│               Hardware                        │
└──────────────────────────────────────────────┘
```

### 2.0.1 计划中的用户态策略拆分（尚未实现）

独立的 **Object / I/O / Security** 服务进程与更清晰的 Loader 边界仅为**设计目标**，见 [Servers.md](Servers.md) §3 与 [LPC_USER_SERVERS_CONTRACT.md](LPC_USER_SERVERS_CONTRACT.md)。

### 2.1 内核态 (Kernel Mode)

#### Microkernel Core

内核只提供最基础的"机制"，不包含策略：

| 职责 | 说明 |
|------|------|
| 调度 | 线程调度、优先级、时间片 (Round-Robin) |
| 虚拟内存 | 地址空间、页表映射/解映射、权限控制 |
| IPC | LPC 端口、同步 call/reply、消息队列 |
| 中断/异常 | IDT 分发、IRQ 处理、异常上送 |
| 系统调用 | x86_64：`syscall`/`sysret` + SSDT 子集（见 [SyscallABI.md](SyscallABI.md)） |
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

#### 系统服务

| 服务 | 职责 | 当前落地 |
|------|------|----------|
| Process Server (PID 1) | 进程/线程生命周期 RPC | **用户态** — `src/servers/server.zig` |
| Session Manager (SMSS, PID 2) | 会话、子系统注册与启动 | **用户态** — `src/servers/smss.zig` |
| Object / I/O / Security「服务器」 | 类似 NT 的用户态策略进程 | **非独立进程** — 逻辑在内核 `src/ob/`、`src/io/`、`src/se/` |
| Loader | PE/ELF 映射、重定位、导入 | **内核** `src/loader/`；用户态拆分 **规划中** |

未来 LPC 端口名见 [Servers.md](Servers.md)；在独立进程落地前，部分端口仅为 **契约/占位**。

#### Subsystems

提供应用兼容层 API：

| 子系统 | 说明 |
|--------|------|
| Native | ZirconOSAero 原生 API 子集 |
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

下列为 Object Manager **已登记的对象种类** — **不表示**每类均已达到 Windows 级语义、syscall 全覆盖或测试完备；多数为 **Partial**，以 [`object.zig`](../../src/ob/object.zig) 与 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 为准。

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

NT 风格命名空间**示意图** — **并非**每个分支均可完整遍历或与 Windows 等深；**`LPC\ObServer`、`IoServer` 等名称不表示**当前已有独立用户态服务进程（见 [Servers.md](Servers.md)）。

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

IPC 是基础能力；**本仓库为混合内核**，大量策略仍在内核 Executive 中，与「一切策略在用户态」的纯微内核叙事不同。

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
