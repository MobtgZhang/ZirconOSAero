# 问题 #33：默认 DACL 返回函数局部值指针

## 1. 问题编号

`33`

## 2. 问题位置

- 文件路径：`src/se/security_descriptor.zig`
- 函数/模块：`SECURITY_DESCRIPTOR.initDefault()`
- 行号或代码片段：修复前 `initDefault()` 在函数内构造默认 ACL 后，将 `sd.dacl` 指向该局部 ACL；函数返回后该指针悬垂。

## 3. 问题描述

`initDefault()` 返回的 `SECURITY_DESCRIPTOR` 中，`dacl` 指向函数局部变量。调用方保存或继续读取该安全描述符时，默认 DACL 可能已经超出生命周期，导致访问判断读到无效 ACL 数据。

## 4. 复现路径

1. 在任意上下文调用 `SECURITY_DESCRIPTOR.initDefault()`。
2. 将返回的 `SECURITY_DESCRIPTOR` 保存到调用方局部变量、对象字段或全局状态。
3. 后续调用 `checkAccess()` 或读取 `sd.dacl`。
4. 原函数局部 ACL 存储已失效，访问检查可能依赖悬垂指针。

## 5. 影响范围

- 影响所有使用默认安全描述符的对象。
- 可能导致访问检查结果不可预测，包括意外拒绝或意外放行。
- 安全上可能表现为权限提升或拒绝服务。
- 稳定性上可能触发未定义行为。

## 6. 严重程度

- Critical

## 7. 可能原因

默认 ACL 被作为函数局部值构造，但安全描述符持有其指针返回。Zig 不会隐式把指针指向的对象提升为调用方生命周期内的存储。

## 8. 权威参考依据

- Microsoft Learn 公开的 Security Descriptor / ACL 语义：DACL 必须在其所属安全描述符可用的生命周期内有效。
- Zig 语言公开的内存与指针生命周期语义：返回值中的指针不能指向已离开作用域的局部变量。
- ReactOS 行为方向：内核对象默认安全描述符由对象管理器生命周期存储支撑；本修复未复制 ReactOS 源码。
- REA 镜像对照：本条未执行 Windows 7 镜像中相关安全描述符函数的 REA 函数级分析。当前 `/tmp/w7-ntoskrnl.rea` 快照没有覆盖该路径的函数级记录，不能声称与镜像逐函数等价。
- `/home/mobtgzhang/api.json`：该文件是 REA provider 配置，不是 Windows API 文档；本条未从中提取行为依据。

## 9. 建议修复方案

把默认 ACL 提升为模块级 `const DEFAULT_DACL`，`initDefault()` 只返回指向该常量的指针。这样默认 DACL 的生命周期覆盖所有返回的安全描述符实例。

修复后 `initDefault()` 的可观察行为是：默认安全描述符始终携带稳定的 DACL 指针；SYSTEM 与管理员仍获得完全访问，普通用户访问掩码不因生命周期修复而改变。

## 10. 验证方法

- 新增 `SECURITY_DESCRIPTOR default DACL is stable and non-null` 测试：连续调用 `initDefault()`，验证两次返回的 DACL 非空且指向同一模块级 ACL。
- 将 `src/se/security_descriptor.zig` 测试接入 `zig build test`。
- 执行 `zig build test`。
- 后续可使用 REA 对 Windows 7 镜像中对应安全描述符初始化函数进行函数级对照，并使用 QEMU 验证对象打开路径。

## 11. 状态

- Fixed

## 12. 修复记录与二进制对照结论

已修复文件：

- `src/se/security_descriptor.zig:28`
- `src/se/security_descriptor.zig:172`
- `src/se/security_descriptor.zig:260`
- `build.zig:837`
- `src/se_security_descriptor_host_test.zig:1`

验证结果：`zig build test` 通过；`git diff --check` 通过。

与原始二进制对照结论：**未对照**。当前 REA 快照没有安全描述符初始化、默认 DACL 或相关 `Se` / `Ob` 路径的函数级记录。结论限定为“已消除源码级悬垂指针并符合公开 NT 安全描述符语义方向；与 Windows 7 镜像逐函数等价性待 REA 验证”。
