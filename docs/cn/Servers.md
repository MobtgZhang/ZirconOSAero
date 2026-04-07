# ZirconOS 系统服务

**当前落地**：**仅** **Process Server**（PID 1）与 **SMSS**（PID 2）是**独立用户态进程**，经 LPC 与内核对话。**Object / I/O / Security** 的策略与实现**仍在内核**（`src/ob/`、`src/io/`、`src/se/`）；独立的 ObServer / IoServer 等进程**尚未**作为产品路径交付。本文同时描述**现状**与 **§3 规划拆分**。

**LPC 用户态拆分契约（草案）**：[LPC_USER_SERVERS_CONTRACT.md](LPC_USER_SERVERS_CONTRACT.md)。

## 1. 服务架构

```
┌──────────────────────────────────────────────────┐
│                  Applications                     │
├──────────────────────────────────────────────────┤
│ Subsystems（Win32 / POSIX 规划 / WOW64 / …）      │
├──────────────────────────────────────────────────┤
│ 用户态服务进程（当前已实现）                        │
│   ┌────────────┐      ┌────────────┐             │
│   │ PsServer   │      │   SMSS     │             │
│   │   PID 1    │      │   PID 2    │             │
│   └─────┬──────┘      └─────┬──────┘             │
│         └─────────┬─────────┘                    │
│                   │ LPC/IPC                       │
├───────────────────┼──────────────────────────────┤
│ 内核 — 微内核 + Executive（OB / IO / SE /       │
│ MM / PS / loader / VFS …）                        │
└──────────────────────────────────────────────────┘
```

**规划中（上图不单独画框）**：用户态 **Object / I/O / Security** 服务进程与 Loader 边界 — 见 §3。

## 2. 已实现的服务

### 2.1 Process Server (PID 1)

- **源码**：`src/servers/server.zig`
- **LPC 端口**：`\LPC\PsServer`
- **职责**：经 LPC 的进程/线程管理（**子集**，非完整 NT PS；覆盖与语义以 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)、`server.zig` 为准）

| 操作 | 说明 |
|------|------|
| 创建进程 | 分配 PID、地址空间、句柄表、Token |
| 创建线程 | 分配 TID、内核栈、用户栈 |
| 终止进程 | 清理资源、关闭句柄、释放内存 |
| 查询信息 | 进程列表、线程状态 |
| 挂起/恢复 | **部分** — 假设 NT 语义前请对照 `server.zig` / 测试 |

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

下列名称含**未来**拆分目标。**当前**仅标注 **用户进程** 的端口对应独立服务二进制；其余可能是**内核侧登记**、桩或路线图 — 工具链或 AI 推理前请在 `src/` 核实。

| 端口名称 | 逻辑所属 | 用途 | 当前落地 |
|----------|----------|------|----------|
| `\LPC\PsServer` | Process Server | 进程/线程 RPC | **用户进程**（PID 1） |
| `\LPC\SmssServer` | Session Manager | 会话与子系统 | **用户进程**（PID 2） |
| `\LPC\ObServer` | Object Manager | 对象/命名空间 | **内核/占位**（§3 拆分前） |
| `\LPC\IoServer` | I/O Manager | 设备与 I/O | **内核/占位**（§3 拆分前） |
| `\LPC\NativeSubsys` | Native 子系统 | 原生 API | **以代码为准**（子系统/内核路径） |
| `\LPC\Win32Subsys` | Win32 子系统 | Win32 API | **以代码为准**（`subsystem.zig` 等） |

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

路线图 **Phase 5** 的意图摘要；**实际**端口创建顺序、哪些端口在内核侧登记，可能因构建而异 — 以 `main.zig` 与服务拉起代码为准。

```
Phase 5（概念）
  1. 登记/创建引导所需 LPC 端口（至少 Ps + SMSS；Ob/Io 名称可能仅内核侧）
  2. 启动 Process Server (PID 1)
  3. 启动 Session Manager / SMSS (PID 2)
  4. SMSS 驱动子系统启动链
Phase 5 结束
```
