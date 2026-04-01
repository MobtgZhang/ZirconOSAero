# LPC 与用户态服务拆分（契约草案）

## 原则

- **内核**：仅保留机制（端口、句柄、调度、页表、原始 IRP 下发）。
- **用户态服务**：Object / I/O / Security **策略**（命名空间规则、设备栈策略、DAC 决策缓存）。

## 消息方向（占位 ID）

| 服务 | 建议端口名前缀 | 请求类型（枚举占位） | 载荷概要 |
|------|----------------|----------------------|----------|
| Object Manager | `\RPC Control\Ob` | `ObCreateHandle`, `ObLookup` | 对象类型、路径、访问掩码 |
| I/O Manager | `\RPC Control\Io` | `IoRegisterDevice`, `IoComplete` | 设备名、IRP  major/minor、缓冲区句柄 |
| Security | `\RPC Control\Se` | `SeAccessCheck` | Token 句柄、SD 句柄、desired access |

实际消息布局须在 `src/lpc/ipc.zig` / `port.zig` 稳定后固化为版本化结构体；本表仅为 **版权安全的接口规划**，不绑定 Windows 私有 RPC 布局。

## 演进步骤

1. 将现有内核内「策略分支」标为 `// TODO: migrate to user server`。  
2. 为每个请求定义 `NtStatus` 映射与超时。  
3. 在 `docs/en/Servers.md` 更新组件图。

## 参考

Microsoft Learn — LPC/ALPC 概念层描述（行为级）；实现为原创。
