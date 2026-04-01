# 参与贡献

感谢关注 ZirconOSAero。提交前请阅读：

1. **[docs/cn/PROCESS_NT61.md](docs/cn/PROCESS_NT61.md)** — 开发流程与 NT 6.1 契约。  
2. **版权**：禁止引用 Windows/ReactOS/Wine **源码**；仅依据 Microsoft Learn、WDK 公开说明、硬件规范与教材级算法。  
3. **构建**：`zig build test`、`bash scripts/ci-qemu-smoke.sh`（本地可选）、`make build`。  
4. **PR**：说明动机、行为变化、如何验证；更新相关 `docs/cn/*_MATRIX.md` 或路线图若影响完成度声明。

## 代码风格

- Zig 0.15.x；内核模块避免 `std.os` 等宿主依赖（见 `.cursor/rules`）。  
- 新 `.zig` 文件使用仓库统一 SPDX + 模块头注释。  
- 裸指针与 `@ptrFromInt` 须注释安全理由（内核规则）。

## Issue

请使用 GitHub Issue 模板（Bug / 功能请求）；安全敏感问题请避免在公开 Issue 中粘贴可利用载荷细节。
