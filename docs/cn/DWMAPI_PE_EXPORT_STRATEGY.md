# dwmapi.dll PE 导出策略（阶段 4 / NT 6.1 ABI）

本文件描述 ZirconOSAero 在 **clean-room** 前提下对 `dwmapi.dll` **公开 ABI** 的对齐方式；实现以 [Microsoft Learn — dwmapi](https://learn.microsoft.com/windows/win32/api/_dwm/) 为唯一签名来源。

## 当前形态（内核内链）

- 运行时代码：[`src/subsystems/win32/dwmapi.zig`](../../src/subsystems/win32/dwmapi.zig)（Zig 函数，非独立 PE）。
- PE 预载桩：[`src/loader/pe.zig`](../../src/loader/pe.zig) `loadDll("dwmapi.dll", …)` 注册 **按名导出** + **合成序号** 1..12，供 `exec` / 导入表解析演练。
- 导出清单单一来源：[`src/config/dwm_nt61_abi_inventory.zig`](../../src/config/dwm_nt61_abi_inventory.zig) `dwmapi_exports_nt61`（须与 `pe.zig` 中 `addExport` 名称与顺序一致）。

## 约定

| 项 | 策略 |
|----|------|
| 导出方式 | **仅名称导出**为主；`pe.zig` 中序号为引导期占位，**不**声称与商业 Win7 `dwmapi.dll` 逐序号一致。 |
| 调用约定 | x64 Windows：`HRESULT` / `BOOL` 与 Learn 一致；结构体为 **MSVC 默认布局**（LP64），见 [`dwm_nt61_api_contract.zig`](../../src/config/dwm_nt61_api_contract.zig)。 |
| WOW64 | PE32 布局与 HWND/`HRGN` 宽度见 [`dwmapi_wow64.zig`](../../src/subsystems/win32/dwmapi_wow64.zig)。 |
| 独立 DLL 映像 | 未来若用 Zig/`lld` 产出真实 `.dll`：应生成与上表相同的导出名，并跑 `dwm_nt61_abi_inventory_host` + `dwmapi_wow64_host`。 |

## 与 WDDM 的边界

VirtIO-GPU scanout 等路径见 [`SOFTWARE_COMPOSITOR_WDDM.md`](SOFTWARE_COMPOSITOR_WDDM.md)：呈现语义 **非** WDDM KMD 二进制协议。
