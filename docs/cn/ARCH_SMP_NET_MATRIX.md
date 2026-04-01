# 多架构、SMP 与网络 — 状态矩阵（维护者填写）

## 架构 CI / 实测（截至本文档添加时）

| 架构 | `zig build kernel`（CI） | QEMU 烟测脚本 | 备注 |
|------|--------------------------|---------------|------|
| x86_64 | 是 | `scripts/ci-qemu-smoke.sh`（MBR 盘 + ELF 断言） | 主路径 |
| aarch64 | 是（交叉编译） | 未纳入默认 CI | 需固件与 `make run-aarch64` 本地验证 |
| riscv64 | 未默认 CI | — | `make run-riscv64` |
| loongarch64 | 未默认 CI | — | GNU-EFI / 固件依赖 |
| mips64el | 未默认 CI | — | 占位与链接脚本 |

## SMP（x86_64）

- **阶段 1**：APIC/IOAPIC 初始化、BSP 定时器。  
- **阶段 2**：AP 启动（INIT-SIPI-SIPI）、per-AP 栈与 `gs/base` 或等价 TLS。  
- **阶段 3**：per-CPU 就绪队列、大锁审计。

## 网络

| 阶段 | 内容 |
|------|------|
| 1 | Virtio-Net PCI 探测与环初始化（QEMU） |
| 2 | ARP + IPv4 + ICMP（ping） |
| 3 | TCP/UDP 子集 |
| 4 | Winsock 兼容 **接口设计**（仅公开 ABI 文档级） |

## 参考

Intel SDM、VirtIO 规范、RFC（网络）；实现保持 clean-room。
