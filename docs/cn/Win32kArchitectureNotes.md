# Win32k：内核化 vs 用户态 LPC — 架构备忘

## 问题

**GDI/User 绘图与窗口管理**在真实 Windows 中大量在内核 **win32k** 中完成；本仓库当前以 **内核 Shell（Aero）+ csrss 风格子系统 + LPC** 组合实现 **子集**。需明确长期路线，避免与 **NT 6.1 契约矩阵** 承诺冲突。

## 方案对比（摘要）

| 维度 | 用户态服务（csrss + LPC，当前主方向） | 内核 win32k 化 |
|------|----------------------------------------|----------------|
| **兼容性** | 与「微内核 + 服务进程」文档一致；与官方 PE 生态对齐需补全 LPC/句柄/共享内存 | 更接近真实 Windows 调用路径；**工程量与攻击面**显著增大 |
| **性能** | 跨进程消息与 GDI 命令有拷贝成本；大块传输依赖 **Section 视图**（见 `mm/section.zig` 路线图） | 同地址空间内核路径延迟更低；需严格 IRQL/锁顺序 |
| **安全与版权** | 与 clean-room 一致；协议自主设计 | 须仅依据公开行为文档实现，禁止参考泄露源码 |

## 建议结论（2026 里程碑）

1. **短期**：完善 **LPC 连接端口 / 通信端口** 分离（[`src/lpc/port.zig`](../../src/lpc/port.zig)）、**Section -backed 缓冲**，支撑 csrss 与内核 **DesktopManagerSpec** 单源配置（见 `zircon_aero_defaults.compositor_config_epoch` 与显示层 trace）。
2. **中期**：在 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 中逐项标注 **user32/gdi32** 为 **Partial**，不默认声称 **二进制级 win32k 等价**。
3. **长期**：若需运行 **未修改微软用户态二进制**，再评估 **受限 win32k** 或 **混合模型**（仅同步原语与句柄在内核，绘制仍在服务进程）。

## 相关文档

- [DesktopManagerSpec.md](DesktopManagerSpec.md)
- [PointerPolicy_NT61.md](PointerPolicy_NT61.md)
- [PROCESS_NT61.md](PROCESS_NT61.md)
