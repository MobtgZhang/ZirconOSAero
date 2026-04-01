# 可复现构建与发布检查清单

本文档与 GitHub Actions [.github/workflows/ci.yml](../.github/workflows/ci.yml) 对齐，便于维护者打 **Release** 时附 `checksums.sha256`。

## 工具链版本

| 组件 | 版本 |
|------|------|
| Zig | **0.15.2**（CI 锁定）；`build.zig.zon` 声明 `minimum_zig_version = "0.15.0"` |
| QEMU（烟测） | `qemu-system-x86`（Ubuntu `ubuntu-latest` 包） |

安装 Zig：<https://ziglang.org/download/>

## 构建入口说明

- **主入口**：`zig build` / `zig build test`（见根目录 [build.zig](../build.zig)）。
- **Makefile / run.sh**：便捷封装（常见目标与 QEMU 参数）；与 CI 对齐时以 `zig build` 与 [.github/workflows/ci.yml](../.github/workflows/ci.yml) 为准。

## 本地命令（x86_64 主线）

```bash
zig version   # 应为 0.15.2（或 ≥0.15.0 且通过本仓库测试）
bash scripts/fetch-assets.sh   # 若尚未提交壁纸 PNG，生成占位图（zig build 前置检查需要）
zig build test
zig build kernel -Darch=x86_64
zig build install -Darch=x86_64 -Doptimize=ReleaseSafe
bash scripts/ci-qemu-smoke.sh
```

`zig build test` 当前包含：`heap`、`pool`、`buddy`、`slab`、`ssdt`、`ssdt_stub_parity`、`ssdt_x64_x86_namespace`、`se_token`、`smp_atomic_host`、`wow64_types`、`object`、`io_irp_host`、`ecam_layout`、`hpet_id`、`lpc_portkind_host`、`minimal_net`、`mdl_host`、`pci_driver_bind_host`、`fs_vfs_constants_host`、`scheduler_policy_host`、`nt61_phase_f_scheduler_gap`、`gpu_device_host`、`virtio_gpu_spec_host`、`display_flip_journal_host`、`win32k_host`、`wow64_ssdt_x86` 等主机单测；与 [NT61_CONTRACT_MATRIX.md](cn/NT61_CONTRACT_MATRIX.md) 中「验证」行一致。

交叉编译与 ZBM 辅助产物（可选；与 CI 矩阵一致）：

```bash
zig build kernel -Darch=aarch64
zig build kernel -Darch=riscv64
zig build kernel -Darch=loongarch64
# RISC-V / LoongArch UEFI ZBM 对象：对应 step 仅在匹配 -Darch 时注册（见 build.zig）。
zig build zbm-riscv64-uefi -Darch=riscv64
zig build zbm-loongarch-uefi -Darch=loongarch64
```

## 发布物建议

在 GitHub **Releases** 中附带：

- 构建说明（本文件链接或摘要）
- 可选：`zig-out/` 产物的 SHA-256 清单（示例：`sha256sum zig-out/bin/* > checksums.sha256`）

## 商标

发行标题与说明避免暗示 Microsoft 官方产品；见各 `README*` 中的独立项目声明。
