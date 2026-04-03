# ntdll / kernel32 / user32 合成 PE 导出策略（NT 6.1 子集）

本策略与 [DWMAPI_PE_EXPORT_STRATEGY.md](DWMAPI_PE_EXPORT_STRATEGY.md) 同构：**不**声称与微软 `System32` 下闭源 DLL 逐导出兼容或可替换；仅锁定仓库内 **已实现子集** 的 **名称顺序 + 合成 ordinal**，供 `pe.zig` 与主机测试双端一致。

## 单一真源

- 导出名称表：`src/config/nt61_core_dll_abi_inventory.zig`（`ntdll_exports_nt61`、`kernel32_exports_nt61`、`user32_exports_nt61`）。
- 合成映像：`src/loader/pe.zig` `initSystemDlls` 中对应 `addExport` **顺序须与上表一致**；修改一方须同步另一方并跑 `zig build test` → **nt61_core_dll_abi_inventory_host**。

## 调用约定

- x64：Microsoft x64 calling convention（与 Learn / ABI 文档一致）。
- 失败与未实现路径：`NTSTATUS` / `LoadStatus` 见 `pe.zig` `loadStatusToNtStatus` 与 [API_COMPAT_MATRIX.md](API_COMPAT_MATRIX.md)「pe / exec」行。

## 搜索路径（占位）

- 进程参数默认 `dll_path`：`C:\Windows\System32`（`pe.zig` `setProcessParameters`）；真实 `LdrLoadDll` 搜索顺序仍为路线图项，须在矩阵标明 **Partial**。
