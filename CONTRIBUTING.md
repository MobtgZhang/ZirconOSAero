# 参与贡献

感谢关注 ZirconOSAero。提交前请阅读：

1. **[docs/cn/PROCESS_NT61.md](docs/cn/PROCESS_NT61.md)** — 开发流程与 NT 6.1 契约。  
2. **版权**：禁止引用 Windows/ReactOS/Wine **源码**；仅依据 Microsoft Learn、WDK 公开说明、硬件规范与教材级算法。请勿提交与 **LGPL-2.1 不兼容** 的依赖源码（例如 **GPLv3** 图标包整包并入内核树）；若需 GPL 素材，须在 [THIRD_PARTY.md](THIRD_PARTY.md) 登记并与维护者确认分发边界。  
   **PR 前自查**：`git grep -iE 'reactos|wine' -- '*.zig' '*.c' '*.h'` 应无第三方实现粘贴；策略性提及 ReactOS/Wine 的 Markdown 说明除外。新增 `extern struct` / 公共 API 须在文件头或行注释写明 **Microsoft Learn / WDK / OASIS VirtIO / 硬件手册** 等公开出处。  
3. **构建**：`zig build test`、`bash scripts/ci-qemu-smoke.sh`（本地可选）、`zig fmt`（提交前）；详见 [docs/REPRODUCE_BUILD.md](docs/REPRODUCE_BUILD.md)。  
4. **PR**：说明动机、行为变化、如何验证；更新相关 `docs/cn/*_MATRIX.md` 或路线图若影响完成度声明。

## 代码风格

- Zig **0.15.2**（与 CI 一致；`build.zig.zon` 要求 ≥0.15.0）；内核模块避免 `std.os` 等宿主依赖（见 `.cursor/rules`）。  
- 新 `.zig` 文件使用仓库统一 SPDX + 模块头注释。  
- 裸指针与 `@ptrFromInt` 须注释安全理由（内核规则）。

## Issue

请使用 GitHub Issue 模板（Bug / 功能请求）；安全敏感问题请避免在公开 Issue 中粘贴可利用载荷细节。
