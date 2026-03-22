# ZirconOS 系统服务

系统服务运行在用户态，通过 LPC/IPC 与微内核通信，提供系统策略和高层管理功能。

## 1. 服务架构

```
┌──────────────────────────────────────────────────┐
│                  Applications                     │
├──────────────────────────────────────────────────┤
│ Subsystems (Win32 / POSIX / WOW64 / Native)      │
├──────────────────────────────────────────────────┤
│          System Services (本文档)                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ PsServer │  │  SMSS    │  │ ObServer │  ...   │
│  │  PID 1   │  │  PID 2   │  │          │        │
│  └─────┬────┘  └─────┬────┘  └─────┬────┘        │
│        │              │              │             │
│        └──────────────┼──────────────┘             │
│                       │ LPC/IPC                    │
├───────────────────────┼──────────────────────────┤
│                  Microkernel                       │
└──────────────────────────────────────────────────┘
```

## 2. 已实现的服务

### 2.1 Process Server (PID 1)

- **源码**：`src/servers/server.zig`
- **LPC 端口**：`\LPC\PsServer`
- **职责**：进程和线程的全生命周期管理

| 操作 | 说明 |
|------|------|
| 创建进程 | 分配 PID、地址空间、句柄表、Token |
| 创建线程 | 分配 TID、内核栈、用户栈 |
| 终止进程 | 清理资源、关闭句柄、释放内存 |
| 查询信息 | 进程列表、线程状态 |
| 挂起/恢复 | 暂停和恢复线程执行 |

### 2.2 Session Manager — SMSS (PID 2)

- **源码**：`src/servers/smss.zig`
- **LPC 端口**：`\LPC\SmssServer`
- **职责**：系统会话管理和子系统引导

| 操作 | 说明 |
|------|------|
| 会话管理 | 创建和管理用户会话 |
| 子系统注册 | 注册 Native / Win32 / POSIX 子系统 |
| 子系统启动 | 按依赖顺序启动子系统服务器 |
| 服务协调 | 协调各系统服务的生命周期 |

## 3. 规划中的服务

以下服务目前以内核内嵌或简化形式存在，计划逐步迁移到独立用户态进程：

| 服务 | 计划目录 | 职责 | 当前状态 |
|------|----------|------|----------|
| Object Server (obsvr) | `servers/obsvr/` | 对象命名空间高层策略、目录/符号链接管理 | 内核内嵌 (`src/ob/`) |
| I/O Server (iosvr) | `servers/iosvr/` | 设备命名空间、VFS 策略、驱动加载管理 | 内核内嵌 (`src/io/`) |
| Security Server (secsvr) | `servers/secsvr/` | Token / ACL / 访问检查策略 | 内核内嵌 (`src/se/`) |
| Loader (ldsvr) | `servers/ldsvr/` | ELF / PE 映射、重定位、导入解析 | 内核内嵌 (`src/loader/`) |

## 4. LPC 通信端口

系统启动后注册的 LPC 端口：

| 端口名称 | 所属服务 | 用途 |
|----------|----------|------|
| `\LPC\PsServer` | Process Server | 进程/线程管理请求 |
| `\LPC\ObServer` | Object Manager | 对象/命名空间操作 |
| `\LPC\IoServer` | I/O Manager | 设备与 I/O 请求 |
| `\LPC\SmssServer` | Session Manager | 会话与子系统管理 |
| `\LPC\NativeSubsys` | Native 子系统 | 原生 API 调用 |
| `\LPC\Win32Subsys` | Win32 子系统 | Win32 API 调用 |

## 5. IPC 消息格式

服务间通过 LPC 消息通信：

```
Message {
    sender:   u32    发送方标识
    receiver: u32    接收方标识
    opcode:   u32    操作码
    data:     [64]u8 消息负载
}
```

### 基本通信模式

| 操作 | 说明 |
|------|------|
| CreatePort | 服务端创建命名端口 |
| ConnectPort | 客户端连接到命名端口 |
| RequestWaitReply | 客户端发送请求并同步等待回复 |
| Reply | 服务端回复消息 |
| Listen | 服务端监听新连接 |

## 6. 启动顺序

系统服务按以下顺序启动（Phase 5）：

```
Phase 5 开始
  1. 创建 LPC 端口 (\LPC\PsServer, \LPC\ObServer, \LPC\IoServer)
  2. 启动 Process Server (PID 1) → 注册进程管理能力
  3. 启动 Session Manager / SMSS (PID 2) → 创建会话、注册子系统
  4. SMSS 发起子系统启动链
Phase 5 结束
```
