# LoongArch64 UEFI 应用程序（PE/COFF）与本仓库工具链

**可检索标签**：`#108`、`loongson-community`、`PE text relocation`、`desktop-src`（用户态 DPI/多显示器参考，**非**本页 UEFI/PE 排错范围；见 `docs/cn/README.md`）。

## 本仓库当前做法

1. **Zig ZBM 对象**：`zig build zbm-loongarch-uefi -Darch=loongarch64` 生成 `zbm_loongarch64.o`（freestanding）。
2. **链接**：[`scripts/build/build-zbm-loongarch64-stub.sh`](../build/build-zbm-loongarch64-stub.sh) 使用 `loongarch64-linux-gnu-ld` + [`boot/stub/linker_stub.lds`](../../boot/stub/linker_stub.lds)，再经 `objcopy --target=pei-loongarch64 --subsystem=efi-app` 产出 `.efi`。
3. **后处理**：[`fix_pe_reloc.py`](fix_pe_reloc.py) 将 PE32+ Optional Header 的 **Subsystem** 修正为 **EFI Application (10)**，避免部分固件 `LoadImage` 返回 Unsupported。

## 与社区讨论 #108 的差异

| 议题（[#108](https://github.com/loongson-community/discussions/issues/108)） | 本仓库 [`fix_pe_reloc.py`](fix_pe_reloc.py) |
|-----------------------------------------------------------------------------|-----------------------------------------------|
| LoongArch64 UEFI **PE 文本段 / 完整重定位**、工具链与 `objcopy pei-loongarch64` 长期方案 | **不处理**：不写入或修复 `.reloc`、不遍历 Base Relocation |
| 社区跟踪的 LLVM / Rust / pe-format 等分支进展 | 若 **LoadImage 已通过** 但 **入口崩溃或指令明显未重定位**，应对照 #108 与上游，用 `readelf -r`、`objdump -d` 查 `.rela` 与入口 |
| 固件 `LoadImage` 因 **Subsystem 等头字段** 返回 Unsupported | **本脚本覆盖**：将 Subsystem 置为 **EFI Application (10)**（与脚本文件头注释一致） |

[LoongArch PE text relocations & Rust LoongArch64 UEFI Preview — loongson-community/discussions#108](https://github.com/loongson-community/discussions/issues/108) 涉及 **PE 文本段重定位**、LLVM/objcopy 与 **LoongArch UEFI** 目标的完整支持（含 heiher 等维护者的 pe-format / llvm / rust 分支）。

本仓库脚本 **不** 实现通用 Base Relocation 修复；若出现 **固件已能加载但入口异常 / 指令未重定位** 一类问题，应对照 #108 及上游 **Zig `loongarch64-unknown-uefi`**、**binutils/objcopy** 更新，用 `readelf -r`、`objdump` 检查 `.rela` / 入口，再评估是否引入公开补丁思路（须保持 clean-room，不复制 Windows/ReactOS 源码）。

## 参考（公开规范）

- UEFI PI / PE/COFF 子集：固件期望的映像布局与 Subsystem 值见 UEFI 规范公开章节。
- Microsoft PE 格式说明（公开）：[PE Format](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format)（Optional Header、Subsystem 字段）。
