# pwsh-lite

自研 **最小 cmdlet 风格管道** 演示程序，**不是** Microsoft PowerShell，不兼容其 cmdlet 名称语义全集。

## 构建

```bash
zig build pwsh-lite
```

可执行文件：`zig-out/bin/pwsh-lite`。

## 用法

将整个管道作为 **一组参数** 传入（空格在引号内保留）：

```bash
./zig-out/bin/pwsh-lite 'Get-Process | Where-Object Name pwsh | Select-Object -Property Name'
./zig-out/bin/pwsh-lite 'Help'
```

## 内置 cmdlet（子集）

`Help`、`Get-Process`、`Get-Item`、`Get-Content`、`Set-Location`、`Get-Location`、`Where-Object`、`Select-Object`、`Sort-Object`、`Measure-Object`。

## 测试

`zig build test` 包含 **pwsh_lite_host**（解析与分词单测）。
