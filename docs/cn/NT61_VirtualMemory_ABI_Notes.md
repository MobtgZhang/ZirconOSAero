# NT 6.1 虚拟内存与显示相关 ABI — 本仓库对照说明

本文档仅汇总 **Microsoft 公开文档** 中的行为要点与 ZirconOSAero 当前实现的对照，供评审与后续补齐；**不包含**任何 Windows 源码级描述。

## 参考（白名单）

- [NtAllocateVirtualMemory](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-zwallocatevirtualmemory)（内核模式 Zw/Nt 对称说明）
- [内存管理常量](https://learn.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-virtualalloc)（用户态 `VirtualAlloc` 的 `MEM_*` 标志与概念对应关系，便于理解 Reserve/Commit）

## NtAllocateVirtualMemory — 语义摘要

| 概念 | 公开文档含义（摘要） | 本仓库现状 |
|------|----------------------|------------|
| 区域保留（Reserve） | 预留 VA 范围，未提交物理后备 | 内核 `mm/vm.zig` 以页表映射为主；完整 `MEM_RESERVE`/`MEM_COMMIT` 分阶段语义仍在演进 |
| 提交（Commit） | 分配实际后备存储（页文件/物理页） | `mm/vm.zig` 中 `mapPageAlloc` / `mapRange` 等价于已提交叶映射；`VirtualCommitPhase` 枚举标注 Reserve/Commit 分阶段路线 |
| 保护属性 | PAGE_READWRITE 等 | 映射标志见 `vm.MapFlags`（可写/可执行/非缓存等） |

## 帧缓冲与大分辨率

- **UEFI GOP / ramfb 手传**：物理地址与 `pitch × height` 必须落在可映射范围内；x86_64 与 LoongArch 在 `main.zig` 中对 **identity 映射未覆盖的 FB 尾部** 有 `mapIdentityByteRange` 补充（非缓存 VirtIO/扫描缓冲）。
- **双缓冲上限**：`framebuffer.zig` 中 `BACK_BUF_MAX` 定义堆后备上限；超过时走日志与降级策略（见 `logFramebufferMemorySummary`）。
- **LoongArch ramfb**：`hal/loongarch64/ramfb.zig` 使用与构建一致的 `kernel_preferred_fb_width/height`（与 `build.conf` / Makefile `ZBM_FB_OPTS` 同源），避免固定 1024×768 与首选 GOP 不一致。

## 用户态 Shell / PE 加载（未来）

- PE 装载与重定位见 `loader/pe.zig`；若加载用户态 Explorer 类组件，虚拟分配应对齐公开 `NtAllocateVirtualMemory` 契约（返回值、STATUS_*、对齐），**独立实现**，不参考封闭源码。

## 版权

实现须遵循仓库 `.cursor/rules` 中的 clean-room 与版权规则；本页只链接 Microsoft Learn 等公开文档。
