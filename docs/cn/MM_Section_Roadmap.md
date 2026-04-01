# 内存：虚拟地址、段对象与 PE 映射（路线图）

目标：在 **不参考私有实现** 的前提下，使行为与公开文档中的 **虚拟内存**、**节区（section）**、**视图（view）** 概念一致（NT 6.1 / Win7 时代 API 面）。

## 参考（公开文档）

- `NtAllocateVirtualMemory` / `NtFreeVirtualMemory` / `NtProtectVirtualMemory` — Win32 API（`winternl`）
- `NtCreateSection` / `NtMapViewOfSection` / `NtUnmapViewOfSection` — 节区与文件映射
- WDK：内存管理器概念（MDL、锁定页面）为 **长期项**

## 阶段划分

1. **当前**：`src/mm/vm.zig` 每进程 `AddressSpace`、`mapPage` / `mapPageAlloc`；`ntdll` 中 `NtAllocateVirtualMemory` 与当前进程空间挂钩。
2. **短期**：`section.zig` + `ntdll` 已实现 **匿名节** 与 `NtMapViewOfSection`/`NtUnmapViewOfSection` 子集；x64 **`syscall` 分发** 已接 `ssdt_nt61` 中 `NtCreateSection`（0x47）/`NtMapViewOfSection`（0x48）/`NtUnmapViewOfSection`（0x2A，Win7 SP1 公开索引）。只读 **文件后备** 映射（与 `vfs`/`FileObject`）仍为后续项。
3. **中期**：PE 映像映射（与 `src/loader/pe.zig` 统一），`SEC_IMAGE` 等标志按 MSDN 语义解析。
4. **长期**：共享节、写时拷贝、子进程继承视图；布局以 `comptime` 测试锁定 `sizeof`/对齐。

## 布局测试

新增结构体（如 `SECTION_BASIC_INFORMATION` 或与文档一致的用户缓冲区布局）时，须在对应 `.zig` 文件中增加 `test "… layout"`，断言 `size`/`offset` 与文档一致。

主机可运行：`zig test tests/nt61/layouts.zig`（`PROCESS_BASIC_INFORMATION` 等，不依赖内核模块）。
