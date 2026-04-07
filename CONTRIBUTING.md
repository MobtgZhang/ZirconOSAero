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

## 目录约定（结构）

- **宿主测试**（`zig build test` 的独立目标）：逻辑放在 [`tests/`](tests/)（含 [`tests/host/`](tests/host/) 与 [`tests/nt61/`](tests/nt61/)）。若测试需 `@import("mm/...")` 等与内核同包路径，Zig 0.15 要求 **模块根目录为 `src/`**；此类用例的 **真源在 `tests/host/*.zig`**，由 [`src/`](src/) 下同名 **符号链接** 指向（`build.zig` 的 `root_source_file` 仍写 `src/...`）。  
- **内核可执行入口**：仅 [`src/main.zig`](src/main.zig)（panic、`kernel_main`、架构分发）；启动与桌面会话逻辑逐步收拢到 `src/kernel/` 等模块。  
- **显示/合成栈**：跨目录引用时优先经 [`src/drivers/video/root.zig`](src/drivers/video/root.zig) 的稳定 re-export，避免深层 `../../../` 穿透。  
- **新增大文件**：先按子域拆模块再合入，单文件不宜长期超过约两千行（显示/Win32 等域允许分多步拆分）。

## Issue

请使用 GitHub Issue 模板（Bug / 功能请求）；安全敏感问题请避免在公开 Issue 中粘贴可利用载荷细节。
