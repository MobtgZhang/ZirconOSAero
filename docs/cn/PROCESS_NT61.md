# ZirconOSAero（NT 6.1 风格）— 严格开发流程

本文档定义与 **Windows 7 / NT 6.1** 体验对齐的实现顺序；所有阶段须在上一阶段可重复构建、可验证后再进入下一阶段。

## 目标与约束

- **内核与体系结构**：混合微内核思路与 NT 风格子系统分层；用户态服务与 Win32 兼容层按里程碑扩展。
- **引导**：仅 **ZirconOS Boot Manager (ZBM)** — BIOS/MBR 链与 UEFI/GPT 链；**不使用 GRUB**。
- **视觉**：默认 **Aero** 桌面（`src/desktop/aero/`），与 Vista/7 玻璃、任务栏、DWM 组合方向一致。
- **架构**：`x86_64`、`aarch64`、`loongarch64`、`riscv64`（及上游已有的 `mips64el`）；UEFI 由 Zig 直接产出（x86_64/aarch64），LoongArch 为 GNU-EFI 链接路径；**RISC-V UEFI** 在 Zig 工具链支持 PE/COFF 前见 `build.zig` 注释与下方阶段说明。

## 阶段划分（必须按序）

### Phase 0 — 工具链与基线构建

- 固定 Zig 版本；`zig build`、`make build` 对主目标架构通过。
- `build.conf`：`BOOTLOADER=zbm`，`DESKTOP=aero`。

### Phase 1 — 引导（ZBM）

- **MBR**：`boot/zbm/bios/`（mbr/vbr/stage2）与 `build-zbm-disk` 生成的磁盘镜像在 QEMU 下可进入菜单并加载内核。
- **UEFI**：`boot/zbm/uefi/main.zig`（及 LoongArch `main_loongarch64.zig`）构建 `.efi`，`make build-esp` 可生成 ESP；菜单文案与配色保持 **Windows 7 启动管理器** 风格（见 `boot/zbm/common/menu.zig`）。
- **ISO**：`scripts/build/mkiso-uefi-zbm.sh` + `xorriso`，无 GRUB。

### Phase 2 — 内核 NT 6.1 语义基线

- 版本与构建标签对外呈现 **NT 6.1** 语义（如 `RtlGetVersion` 风格信息、内核日志前缀）；与 Phase 0–11 启动路径文档一致（见 `docs/en/Kernel.md`）。

### Phase 3 — 子系统与用户态

- 对象管理器、进程/LPC、I/O、安全描述符等按依赖顺序实现；与 [ZirconOS](https://github.com/MobtgZhang/ZirconOS) 上游目录结构对齐并做 NT6.1 行为差分。
- 子里程碑拆分见 [ExecutivePhase3_Milestones.md](ExecutivePhase3_Milestones.md)。

### Phase 4 — Aero 桌面与合成

- 以 `src/desktop/aero/` 为主线：合成器、主题加载、任务栏与 Shell；资源在 `resources/` 下维护。
- **规格**：[DesktopManagerSpec.md](DesktopManagerSpec.md)（方案 B：内核 present + 用户态合成树 / Hit-test；`zircon_aero_defaults` 对齐玻璃参数）。
- **验证**：[DesktopQA.md](DesktopQA.md)、`scripts/desktop-qa.sh`。

### Phase 5 — 多架构回归

- 每架构至少：`make build ARCH=…`、`make build-esp`（若适用）或 `LOONGARCH64_QEMU_MODE=kernel` 直启；记录已知限制（如 RISC-V UEFI 链接）。

## 验证门禁

每个阶段合并前须满足：

1. 默认配置下可完整构建。
2. 与本阶段相关的 `make test-*` 或脚本测试通过（随仓库更新）。
3. 文档（本文件 + `docs/en/Boot.md`）中引导路径描述与实现一致。

## 参考

- 上游设计与完整功能矩阵：[MobtgZhang/ZirconOS](https://github.com/MobtgZhang/ZirconOS)
- 英文引导说明：`docs/en/Boot.md`（需随本仓库「仅 ZBM」策略同步修订）。
