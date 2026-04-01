# ZirconOSAero 版权与知识来源

本仓库为 **clean-room** 自研实现，目标为在公开文档所描述的接口上与 NT 6.1（Windows 7 时代）ABI 兼容。

## 允许参考

- [Microsoft Learn](https://learn.microsoft.com/) / WDK 中公开的 API、结构体布局与行为说明  
- Intel / AMD / ARM / RISC-V / LoongArch 等**公开发布**的硬件规范  
- ACPI、UEFI、PCI 等行业公开规范  
- 教科书与架构文章中的**概念**（不得复制受版权保护的代码）

## 禁止

- 任何 Windows 内核或用户态**源代码**（含泄露版本）  
- **直接复制** ReactOS、Wine 等第三方实现源码（若将来引用须完整遵循其许可证并单独审计）

## ABI 与实现

- 使用与 Windows 相同的**公开**函数名、结构体名、常量值属于 **ABI 兼容**，不视为复制实现。  
- **算法、控制流与注释**须独立编写，并能在代码审查中说明依据（文档行为或自主设计）。

贡献代码前请同时阅读仓库根目录 [.cursor/rules](.cursor/rules) 中的项目规则。
