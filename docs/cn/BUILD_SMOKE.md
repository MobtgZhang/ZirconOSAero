# 构建与多架构冒烟（阶段 A–E1）

## 本地门禁

- `zig build`：默认目标 `x86_64-freestanding-none` 内核。
- `zig build test`：主机单测（SSDT、WOW64、池、布局等）；合并前须绿。

## 多架构编译冒烟（A–E1）

在仓库根目录执行（仅需编译通过，无需 QEMU）：

```bash
zig build -Darch=aarch64
zig build -Darch=riscv64
zig build -Darch=loongarch64
```

（可选）`mips64el` 与 CI 矩阵以 [.github/workflows/ci.yml](../../.github/workflows/ci.yml) 为准。

## SMP / LAPIC 定时器 / TLB IPI（阶段 J 烟测）

- 脚本：[scripts/qemu_smp_smoke.sh](../../scripts/qemu_smp_smoke.sh)（`-smp 4` + `-kernel zig-out/bin/kernel`；可按环境改 `KERNEL`）。
- x86_64：**`-Dsmp_tlb_ipi`** 默认为 `true`；**`-Dlapic_periodic_tick`** 为每核 LAPIC LVT 周期 tick（与 BSP 一致 mask PIC IRQ0 的策略仅 BSP Phase3 执行）。

## AHCI + VFS 烟测（阶段 H2）

QEMU `q35` 示例（磁盘镜像路径自行替换）：

```bash
qemu-system-x86_64 -machine q35,ahci=on -drive file=disk.img,format=raw,if=none,id=d0 \
  -device ide-hd,drive=d0,bus=ahci.0 -serial stdio -kernel zig-out/bin/kernel
```

成功时串口可见 `AHCI:` IDENTIFY / DMA read LBA0 与可选 `VFS: AHCI probe mount E:\`。

## 矩阵季度核对（A–E2）

每季度对照 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)、[README_cn.md](../../README_cn.md) 与 `src/` 实现，将 **Partial / Stub** 与文档同步；勿仅改文档不跑 `zig build test`。
