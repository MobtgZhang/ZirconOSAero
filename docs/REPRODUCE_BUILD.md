# 可复现构建与发布检查清单

本文档与 GitHub Actions [.github/workflows/ci.yml](../.github/workflows/ci.yml) 对齐，便于维护者打 **Release** 时附 `checksums.sha256`。

## 工具链版本

| 组件 | 版本 |
|------|------|
| Zig | **0.15.2**（与 CI `mlugg/setup-zig` 一致） |
| QEMU（烟测） | `qemu-system-x86`（Ubuntu `ubuntu-latest` 包） |

安装 Zig：<https://ziglang.org/download/>

## 本地命令（x86_64 主线）

```bash
zig version   # 应为 0.15.2
zig build test
zig build kernel -Darch=x86_64
zig build install -Darch=x86_64 -Doptimize=ReleaseSafe
bash scripts/ci-qemu-smoke.sh
```

交叉编译烟测（可选）：

```bash
zig build kernel -Darch=aarch64
```

## 发布物建议

在 GitHub **Releases** 中附带：

- 构建说明（本文件链接或摘要）
- 可选：`zig-out/` 产物的 SHA-256 清单（示例：`sha256sum zig-out/bin/* > checksums.sha256`）

## 商标

发行标题与说明避免暗示 Microsoft 官方产品；见各 `README*` 中的独立项目声明。
