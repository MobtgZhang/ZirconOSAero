# 问题 #1：配置迁移后构建配置测试与向导仍依赖已删除文件

## 1. 问题编号

`1`

## 2. 问题位置

- 文件路径：`tests/test_build_config.py`、`scripts/devtools/configure.py`
- 函数/模块：配置测试入口、`parse_build_conf`、`test_zbm_iso_script`、`read_current_conf`、`write_conf`
- 相关提交：`4970182` 删除 `build.conf`、`run.sh` 与旧工具；后续 `c2a8092` 明确 Makefile 为配置入口

## 3. 问题描述

生产构建配置已经迁移到 `Makefile` 的 `?=` 默认值与命令行覆盖机制，但配置测试仍强制要求不存在的根目录 `build.conf`，并检查仓库中不存在的 `scripts/build/mkiso-uefi-zbm.sh`。配置向导仍读取并写入已删除的 `build.conf`，因此测试会报告迁移后的正常状态为失败，向导生成的配置也不会影响现行 Makefile 构建。

## 4. 复现路径

在项目根目录运行：

```text
python3 tests/run_all.py --suite config --output-dir /tmp/zircon-config-tests
```

修复前实测结果为 `10 passed, 4 failed`，失败项包括 `build.conf` 不存在和 `mkiso-uefi-zbm.sh` 不存在。`Makefile` 本身的 `make -n show-config` 可成功执行。

## 5. 影响范围

- 配置回归测试无法反映当前构建系统状态，CI/本地验证会产生错误失败。
- 配置向导无法读取现行默认值，也无法持久化到现行构建入口。
- 文档与测试继续暗示旧的 ISO helper 存在，掩盖了当前 Makefile 中没有独立 ISO 目标这一待验证/待补齐能力。

## 6. 严重程度

- Medium

## 7. 可能原因

`build.conf` 删除后的代码迁移只更新了 Makefile，未同步更新测试和开发工具；旧测试中的 ISO helper 检查也没有改为当前实际存在的架构 ESP helper 检查。

## 8. 权威参考依据

- 项目源码：`Makefile` 顶部声明“所有配置已合并到此文件”，并定义 `ARCH`、`BOOT_METHOD`、`BOOTLOADER`、`DESKTOP`、`OPTIMIZE` 等 `?=` 默认值。
- Git 历史：提交 `4970182` 删除旧配置文件；提交 `e64399c` 将配置合并到 Makefile；提交 `c2a8092` 更新现行 GNU Make 配置。
- 实际验证：`python3 tests/run_all.py --suite config` 的失败输出，以及 `make -n show-config` 成功输出。
- REA/Windows 7 镜像对照：本问题属于项目构建工具链，不依赖 Windows 7 二进制行为；因此不应虚构 REA 证据。当前 ISO 仍需进一步通过 UDF 读取后再开展 PE 行为分析。
- `/home/mobtgzhang/api.json`：该文件仅包含模型/API 接入配置，不包含 Windows API 符号或行为描述，不能作为本问题的行为依据。

## 9. 建议修复方案

- 让测试读取 Makefile 的字面量 `?=` 默认值，并通过 `make show-config` 验证命令行覆盖。
- 将 UEFI helper 检查改为仓库实际存在的 `mkesp-x86_64.sh`、`mkesp-aarch64.sh`、`mkesp-riscv64.sh`、`mkesp-loongarch64.sh`。
- 让配置向导读取 Makefile 默认值并输出可直接传给 `make` 的赋值，不再写入已删除的 `build.conf`。
- 将 ISO 生成能力作为独立问题继续审查，不用伪造一个缺失脚本来使测试通过。

## 10. 验证方法

- 运行 `python3 tests/run_all.py --suite config`，确认配置测试不再因缺少 `build.conf` 或旧 helper 失败。
- 运行 `make -s show-config ARCH=aarch64 DESKTOP=none`，确认命令行覆盖生效。
- 运行 `python3 scripts/devtools/configure.py`，确认向导读取 Makefile 默认值并输出 `make KEY=value` 赋值。
- 后续补齐真实 ISO 目标后，再增加针对 ISO 产物结构的测试。

## 11. 状态

- Fixed

## 12. 修复说明

已更新 `tests/test_build_config.py` 与 `scripts/devtools/configure.py`，保持 Makefile 为唯一生产配置源，避免恢复已删除的旧文件。该修复不改变内核、驱动或公共运行时接口。
