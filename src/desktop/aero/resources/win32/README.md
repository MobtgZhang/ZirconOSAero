# Win32 宿主资源（ICO / 资源 DLL）

用于在 **Windows 或 MinGW 交叉环境** 下生成与 NT 壳层语法兼容的图标 DLL，供 Resource Hacker 等工具对照；**不包含**任何微软二进制资源。

## 文件

| 文件 | 说明 |
|------|------|
| `zircon_icon_ids.h` | PE 图标资源 ID 宏（101–125） |
| `zircon_shell32_res.rc` | 引用 `ico/*.ico` |
| `zircon_shell32_res_stub.c` | 最小 `DllMain`，使 DLL 可被 Windows 7+ `LoadLibrary` 正常加载 |
| `ICON_RESOURCE_IDS.md` | `IconId` ↔ PE ID ↔ 文件名 |
| `ico/` | 运行 `scripts/build/build-aero-icons.sh` 后生成的多尺寸 ICO（目录内 `*.ico` 默认不提交） |

## 构建

1. 生成 ICO：`../../../../../scripts/build/build-aero-icons.sh`（自仓库根目录亦可直接调用该脚本）。
2. 生成 DLL：`../../../../../scripts/build/build-zircon-icon-dll.sh`  
   依赖：`x86_64-w64-mingw32-windres` 与 `x86_64-w64-mingw32-gcc`（可通过环境变量 `WINDRES` / `MINGW_GCC` 覆盖）。

产物：`zig-out/assets/zircon_shell32_res.dll`。

## 规范引用

ICO 尺寸建议见 Microsoft Learn 离线树中的 `uxguide/vis-icons.md`；项目内总述见 `docs/cn/NT61_ShellIcons.md`。
