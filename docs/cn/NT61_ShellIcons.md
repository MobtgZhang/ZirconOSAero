# NT 6.1 壳层图标与 ZirconOS 资源 DLL

本文说明 **Windows 7 公开知识** 中的系统图标存放位置、ZirconOS **原创** 资产的对应关系，以及 **与 Win32 兼容** 的宿主侧资源 DLL 构建方式。  
**禁止**从 Windows 安装介质提取或复刻 `shell32.dll` / `imageres.dll` 等中的位图；合规总览见 [Assets.md](Assets.md) 与仓库 `.cursor/rules/zig-nt61-copyright-safety-testing.mdc`。

## 1. Windows 7 参考：主要图标资源文件

### 1.1 `%SystemRoot%\System32\shell32.dll`

最大的图标库之一（公开描述为数百枚量级），涵盖：文件夹、驱动器、计算机、回收站、控制面板项、网络、打印机、快捷方式箭头等。

### 1.2 `%SystemRoot%\System32\imageres.dll`

Windows 7 起常见的高分辨率图标库（含 256×256 PNG 等），涵盖设备、媒体、系统状态（信息/警告/错误）、用户与安全、网络等。

### 1.3 其他 DLL / EXE（摘要）

- `imagehlp.dll`、`pifmgr.dll`、`moricons.dll`、`wmploc.dll`、`setupapi.dll`、`ddores.dll`、`accessibilitycpl.dll`、`netcenter.dll` / `netshell.dll` 等各有专项图标。
- `explorer.exe`、`notepad.exe`、`calc.exe` 等 EXE 自带应用程序图标。

### 1.4 如何查看（工具）

Resource Hacker、IcoFX 等可浏览 PE 资源；「更改图标」对话框中的 `dll,-<id>` 语法见 Microsoft Learn（离线可参考 `desktop-src/shell/shextracticonsw.md` 等）。

> 公开文档**不提供**与 `shell32`/`imageres` **逐索引**的完整列表；ZirconOS 使用**自有**资源编号。

## 2. ZirconOS 策略：逻辑对应微软、内容不对应二进制

| 逻辑角色 | 本仓库构建产物 | 说明 |
|----------|----------------|------|
| 壳层系统图标（合并库） | `zircon_shell32_res.dll` | 仅 `RT_ICON` / `RT_GROUP_ICON`；资源 ID **101–125**（见下文） |
| LoongArch64 /「Windows for LoongArch64」占位 | `zig-out/assets/loongarch64/win/System32/` | **非 PE**：Zig 尚不能产出 `loongarch64-windows-gnu` COFF DLL（`UnsupportedCoffArchitecture`）。本目录为 **ICO 平铺 + `zircon_shell32_res.manifest.json`**，语义对齐 `dll,-<id>` 与 PE 机器码 **0x6264**（`IMAGE_FILE_MACHINE_LOONGARCH64`），供宿主/测试按 manifest 解析。 |
| 可选拆分 | `zircon_imageres_res.dll` | 规划中；当前与上者合并为一个 DLL 以简化工具链 |
| 矢量主源 | `src/desktop/aero/resources/icons/*.svg` | 规格见同目录 `DESIGN.md` |

Shell 引用形态与 Win7 一致（例如 `zircon_shell32_res.dll,-101`），但 **整数 ID 与微软 DLL 不同**，美术为 **LGPL/自有原创**。

### 2.1 LoongArch PE 与社区进展（兼容策略）

- **PE32+ `.rsrc`** 的资源目录布局与 COFF `Machine` 字段正交：只要映像为 **PE32+（magic 0x20B）** 且资源目录有效，即可按类型/语言 ID 遍历。本仓库的 **`.rsrc` 解析**（[`pe_icon_resource.zig`](../../src/desktop/aero/src/pe_icon_resource.zig)）对白名单内的 **COFF 机器类型** 均允许解析，包括 **AMD64 `0x8664`**、**ARM64 `0xAA64`**、**LoongArch32/64 `0x6232`/`0x6264`**，以及 UEFI 规范中的 **RISC-V32/64/128 `0x5032`/`0x5064`/`0x5128`**（见 [UEFI 2.10 — Debugger Support](https://uefi.org/specs/UEFI/2.10_A/18_Protocols_Debugger_Support.html)）。**不**表示 Zig 已能产出对应的 `*-windows-gnu` 资源 DLL；工具链缺口与 LoongArch 类似。
- 龙芯社区讨论 **[LoongArch PE text relocations & Rust LoongArch64 UEFI Preview（#108）](https://github.com/loongson-community/discussions/issues/108)** 聚焦 **UEFI/实验工具链** 下的 LoongArch PE 与重定位、LLVM/Rust 分叉等，**不等于**「任意 Windows 用户态加载器已可像 x64 一样加载带 `.rsrc` 的 LoongArch DLL」。Zircon 在 **Tier 1** 仍交付 **`ico_bundle` + manifest**；**Tier 2** 依赖 Zig/LLVM 对 **`loongarch64-windows-gnu` COFF** 的成熟（可用 **`zig build aero-loongarch-windows-pe-probe`** 探测；当前常见结果为失败直至上游支持）。
- **双轨**：真 PE DLL（x86_64）与 LoongArch 目录占位 **语义对齐**（同一 `shell_reference` / PE 资源号）；宿主侧可按 manifest 的 **`binary_form`** 选择 ICO 或 PE（见 [`pe_icon_loader.loadIconFromShellSystem32Dir`](../../src/desktop/aero/src/pe_icon_loader.zig)）。

## 3. Win32 / Windows 7 API 兼容性说明

本仓库生成的 `zircon_shell32_res.dll` 为 **合法 PE 动态库**，含标准 **`DllMain`**（见 `resources/win32/zircon_shell32_res_stub.c`），可在 Windows 7 及以上：

- **`LoadLibraryW` / `LoadLibraryExW`** 加载模块；
- **`FindResource` / `LoadResource`** 或上层 **`LoadImage`**、**`ExtractIconEx`**（传入模块实例与资源 ID）按 **整数资源 ID** 取图标。

这与系统自带 `shell32.dll` 的「资源 DLL」用法一致，**不涉及**复制微软导出表或实现其内部 API。Zircon 内核路径仍使用 [`icons.zig`](../../src/drivers/video/desktop/icons.zig) 内嵌位图 + SVG 清单；PE 解析留在未来用户态。

**公开规范引用**（本地 `desktop-src` 镜像路径示例）：

| 用途 | 文档路径 |
|------|----------|
| ICO 多尺寸、Aero 造型 | `uxguide/vis-icons.md` |
| `dll,-资源号` 语义 | `shell/shextracticonsw.md`、`shell/schema-librarydescription.md` |

## 4. 逻辑 ID、PE 资源 ID 与文件

| IconId（1–25） | PE 资源 ID | 基名（SVG/ICO） |
|----------------|------------|-----------------|
| 1–25 | 101–125 | 见 `src/desktop/aero/resources/icons/README.md` 与 `resources/win32/ICON_RESOURCE_IDS.md` |

Zig 中 ID 25 的枚举成员名为 **`err`**（`error` 为语言保留字）；文件仍为 `error.svg`。

## 5. 类别映射与后续缺口（相对 Win7 来源）

| Win7 类别 | ZirconOS | 备注 |
|-----------|----------|------|
| shell32 文件夹/文档/计算机/网络/控制面板 | 已有 SVG | `IconId` 1–13 等 |
| 回收站空/满 | `recycle_bin`、`recycle_bin_full` | |
| 磁盘/光驱/U 盘 | `drive_fixed`、`drive_optical`、`drive_removable` | |
| 打印机 | `printer` | |
| 信息/警告/错误 | `info`、`warning`、`error.svg`（逻辑 `err`） | |
| 播放器细分、MMC、IE 框架等 | 未成套 | 长期 P2 |

## 6. 构建命令与产物

| 步骤 | 命令 | 依赖 |
|------|------|------|
| SVG → ICO | `./scripts/build/build-aero-icons.sh` | `inkscape` 或 `rsvg-convert`；`magick` 或 `convert` |
| ICO + RC → DLL | `./scripts/build/build-zircon-icon-dll.sh` | MinGW `windres` + **`zig cc -target x86_64-windows-gnu`**；可选 `SKIP_AERO_ICO_BUILD=1` |
| 集成（推荐） | `zig build aero-shell-icons-dll` | 宿主机：`windres` + **`zig cc -target x86_64-windows-gnu -shared`**（MinGW ABI），产物安装到 `zig-out/assets/` |
| LoongArch 资源包（无 DLL） | `zig build aero-shell-icons-la-bundle` | 将 **25 个 ICO** + **`zircon_shell32_res.manifest.json`** 安装到 **`zig-out/assets/loongarch64/win/System32/`**；依赖与 DLL 相同（或 `-Daero-skip-ico-build=true` 复用 `ico/`） |
| 跳过 ICO 重生 | `zig build -Daero-skip-ico-build=true aero-shell-icons-dll` | 复用已有 `resources/win32/ico/*.ico` |
| 自定义 windres | `zig build -Daero-windres=/path/to/windres aero-shell-icons-dll` | 默认 `x86_64-w64-mingw32-windres` |
| Tier 2 探测（可选） | `zig build aero-loongarch-windows-pe-probe` | 调用 `scripts/build/probe-loongarch-windows-gnu-shared.sh`；**预期在工具链未支持时失败**（如 `UnsupportedCoffArchitecture`），CI 可用 `continue-on-error` |
| 预留选项 | `-Daero-la-pe-dll` | **当前仅占位**；将来用于打开 LoongArch 真 PE 资源 DLL 构建（默认 false，仍以 `aero-shell-icons-la-bundle` 为主） |

产物：

- ICO：`src/desktop/aero/resources/win32/ico/*.ico`（默认 `.gitignore`，可重现生成）
- DLL：`zig-out/assets/zircon_shell32_res.dll`（`zig-out/` 已全局忽略）
- LoongArch 包：`zig-out/assets/loongarch64/win/System32/*.ico` 与同目录 **`zircon_shell32_res.manifest.json`**（字段含 `logical_id`、`pe_resource_id`、`shell_reference`、`pe_machine` / `binary_form: ico_bundle`；与 [ICON_RESOURCE_IDS.md](../../src/desktop/aero/resources/win32/ICON_RESOURCE_IDS.md) 一致）

## 7. 相关源码与 PE 解析（clean-room）

- 内核绘制：[`src/drivers/video/desktop/icons.zig`](../../src/drivers/video/desktop/icons.zig)
- 资源登记：[`src/desktop/aero/src/resource_loader.zig`](../../src/desktop/aero/src/resource_loader.zig)
- PE ID 常量：[`src/desktop/aero/src/icon_resource_ids.zig`](../../src/desktop/aero/src/icon_resource_ids.zig)
- `.rsrc` 按类型/ID 取原始字节（无 Win32 调用）：[`src/desktop/aero/src/pe_icon_resource.zig`](../../src/desktop/aero/src/pe_icon_resource.zig)
- 读盘 + `RT_GROUP_ICON` 探测：[`src/desktop/aero/src/pe_icon_loader.zig`](../../src/desktop/aero/src/pe_icon_loader.zig)（`ready=true` 表示已定位资源块；DIB/PNG 解码后续再做）
- manifest `binary_form`：[`shell_icons_manifest.zig`](../../src/desktop/aero/src/shell_icons_manifest.zig)；目录布局入口 **`loadIconFromShellSystem32Dir`**

## 8. 与 Aero 渲染文档的关系

帧缓冲与 `IconId` 映射见 [AeroRendering.md](AeroRendering.md)。
