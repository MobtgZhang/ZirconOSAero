# 内存：虚拟地址、段对象与 PE 映射（路线图）

目标：在 **不参考私有实现** 的前提下，使行为与公开文档中的 **虚拟内存**、**节区（section）**、**视图（view）** 概念一致（NT 6.1 / Win7 时代 API 面）。

## 参考（公开文档）

- `NtAllocateVirtualMemory` / `NtFreeVirtualMemory` / `NtProtectVirtualMemory` — Win32 API（`winternl`）
- `NtCreateSection` / `NtMapViewOfSection` / `NtUnmapViewOfSection` — 节区与文件映射
- WDK：内存管理器概念（MDL、锁定页面）为 **长期项**

## 阶段划分

1. **当前**：`src/mm/vm.zig` 每进程 `AddressSpace`、`mapPage` / `mapPageAlloc`；`ntdll` 中 `NtAllocateVirtualMemory` 与当前进程空间挂钩。
2. **短期**：`section.zig` + `ntdll`：**匿名节**、`SEC_IMAGE` 文件节标志、`NtMapViewOfSection`/`NtUnmapViewOfSection`；可写文件后备为 **eager copy**（非 COW）；`vm.AddressSpace.section_view_token` 单调 token 供 LPC 绑定。x64 分发见 `syscall_dispatch_mm.zig`。真 **写时拷贝** 与只读共享仍为后续项。
3. **中期**：PE 映像映射（与 `src/loader/pe.zig` 统一），`SEC_IMAGE` 等标志按 MSDN 语义解析。
4. **长期**：共享节、写时拷贝、子进程继承视图；布局以 `comptime` 测试锁定 `sizeof`/对齐。

### 分页文件（pagefile）与文件 WRITECOPY

- **分页文件后备节**：尚未实现；`NtCreateSection` 无文件句柄路径为 **匿名** 内存节。引入真实 pagefile 前须在本文与 `NT61_CONTRACT_MATRIX` 标注 **Partial**，避免静默成功。
- **文件后备 + `PAGE_WRITECOPY` 真 COW**：`section.zig` 当前返回 `STATUS_NOT_IMPLEMENTED`；依赖 `#PF` 路径、只读共享映射与 PFN 引用计数（见 [PFN_REFCOUNT_ROADMAP.md](PFN_REFCOUNT_ROADMAP.md) 若存在）分阶段落地。

### 句柄生命周期（阶段 A 修复）

- 节对象头 `ref_count` 在 `NtCreateSection` 分配句柄前为 **0**；`allocHandle` 递增引用，`NtClose` 至零时经 `ob/cleanup_hooks.zig` 调用 `releaseSectionObject` 回收静态槽。
- **仍映射视图时关闭节句柄**：完整 NT 语义须拒绝或延迟销毁；当前为已知差距（见 `section.zig` 注释）。

## 阶段 A 验收：`linkKernelHalfMappings` 与 CR3

- **`vm.linkKernelHalfMappings`**（`vm.zig`）：将内核 `AddressSpace` 的 PML4 项 **256..511** 复制到进程 PML4，使切换 `CR3` 后仍可达内核高半区；与 **`releaseUserHalfAddressSpace` / `releaseProcessAddressSpace`** 仅回收用户半区 **0..255** 一致。
- **禁止**：在进程 teardown 时释放共享的内核高半区子树（PDPT/PD/PT 帧与内核 PML4 共享；仅释放进程独有用户侧页表与叶帧）。
- **调度**：`scheduler.activateCr3ForProcessId` 与 `process.createProcess` / `terminateProcess` 须在「无线程再以旧 CR3 运行」后再 `releaseProcessAddressSpace`（见 `VM_ISOLATION.md`、`ps/process.zig` 注释）。

### `SEC_IMAGE`、多进程只读共享（路线图验收）

- **`SectionObject.shared_image_candidate` / `is_image_section`**：`section.zig` 标志位；完整 **同一 `SectionObject` 在多 CR3 上映射同一后备物理帧** 依赖 PFN 共享引用与 `active_view_count` / 视图 token 规则（与上节 K1 延后项一致）。
- **验收**：PE 加载器与 `NtMapViewOfSection` 对 `SEC_IMAGE` 的路径在矩阵标 **Partial** 直至本节「多进程同一映像只读」可测。

## 布局测试

新增结构体（如 `SECTION_BASIC_INFORMATION` 或与文档一致的用户缓冲区布局）时，须在对应 `.zig` 文件中增加 `test "… layout"`，断言 `size`/`offset` 与文档一致。

主机可运行：`zig test tests/nt61/layouts.zig`（`PROCESS_BASIC_INFORMATION` 等，不依赖内核模块）。
