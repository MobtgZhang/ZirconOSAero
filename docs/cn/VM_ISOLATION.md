# 用户/内核地址空间隔离（现状与目标）

## 已实现机制（代码路径）

- **独立页表**：`ps/process.zig` 中 `createProcess` 为每个进程分配 `vm.AddressSpace`（新 PML4 等）。
- **映射标志**：`vm.MapFlags.user` / `Write` / `NoExecute` 对应用户可访问页（公开分页语义）。
- **惰性提交**：`AddressSpace.tryLazyCommitFault` + `vm.handleLazyCommitFault`；合法保留区缺页可提交匿名页。
- **用户态缺页**：`ke/interrupt_x86.zig` 中 `#PF` 且 error code 含 user 位时，先尝试 lazy commit，失败则 `terminateProcess` 并记录 `ACCESS_VIOLATION` 语义（0xC0000005 为应用退出码占位）。

## 与路线图差距（Next steps）

- **内核半区**：须保证用户页表不映射内核私有映射（或采用 separate kernel page table + trampoline）；当前以混合内核为过渡时，须在契约矩阵中标注实测范围。
- **CR3 切换**：用户线程运行路径上须在 syscall/调度点激活进程页表（`AddressSpace.activate`）；与 `syscall.zig` / 调度器联调为持续工作项。
- **自动化测试**：QEMU 下运行故意访问未映射内核 VA 的用例，期望进程终止而非 `KeBugCheck` 式整内核停机（可在 `tests/` 增加脚本化场景）。

## 参考

- Intel SDM：页级保护、U/S 位、#PF error code。
- Microsoft Learn：`VirtualAlloc` / 虚拟内存（行为级描述，非实现）。
