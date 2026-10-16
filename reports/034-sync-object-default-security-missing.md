# 问题 #34：内核同步对象池缺少默认安全初始化

## 1. 问题编号

`34`

## 2. 问题位置

- 文件路径：`src/libs/ntdll.zig`
- 函数/模块：`allocEventObject()`、`allocMutexObject()`、`allocSemaphoreObject()`
- 行号或代码片段：修复前三个池分配函数创建 `ob.ObjectHeader` 后没有调用 `ensureDefaultSecurity()`。

## 3. 问题描述

事件、互斥体和信号量对象从静态池分配后，`ObjectHeader.security` 可能为空。对象管理器在访问检查时对未附加安全描述符的对象采用 fail-open 行为，普通用户可能获得不应默认持有的访问权限。

## 4. 复现路径

1. 调用 `NtCreateEvent`、`NtCreateMutant` 或 `NtCreateSemaphore` 创建池内同步对象。
2. 使用非提升普通用户令牌请求超出默认 DACL 的访问。
3. 访问检查读取 `ObjectHeader.security`。
4. 由于该指针为空，检查路径可能放行本应拒绝的访问。

## 5. 影响范围

- 影响内核同步对象的权限控制。
- 可能允许非提升用户打开、同步或操纵未授权对象。
- 与 Windows 7 默认对象安全语义存在偏差。
- 安全上表现为权限提升风险；稳定性上会破坏对象访问模型一致性。

## 6. 严重程度

- High

## 7. 可能原因

池分配路径只初始化了对象类型、状态和池元数据，没有统一执行默认安全描述符初始化。对象默认安全被假设为上游调用方的职责，但同步对象池没有补齐该步骤。

## 8. 权威参考依据

- Microsoft Learn 公开的 Object Manager / Kernel Objects 语义：打开内核对象需要进行访问检查，安全描述符决定可授予访问掩码。
- Microsoft Learn 公开的 Default DACL 概念：普通内核对象应关联安全描述符，SYSTEM 与特权主体可访问，普通用户按 DACL 限制。
- ReactOS 行为方向：对象管理器在对象打开与创建路径上执行安全检查；本修复未复制 ReactOS 源码。
- REA 镜像对照：本条未执行 Windows 7 镜像中 `NtCreateEvent`、`NtCreateMutant`、`NtCreateSemaphore` 或相关 Object Manager 函数的 REA 函数级分析。当前 `/tmp/w7-ntoskrnl.rea` 快照只有 `ExFlushLookasideListEx` 与 `ExInterlockedPopEntryList` 两个函数级记录。
- `/home/mobtgzhang/api.json`：该文件是 REA provider 配置，不是 Windows API 文档；本条未从中提取行为依据。

## 9. 建议修复方案

在三个池分配函数中，把新对象放入静态槽位后立即调用 `ensureDefaultSecurity()`。这保证 `ObjectHeader.security` 指向对象自身的 `security_storage`，生命周期与对象一致。

修复后默认访问行为是：SYSTEM 与提升令牌可访问；普通用户对默认 DACL 未授予的访问位被拒绝。对象槽位回收后重新分配时，也会重新初始化默认安全。

## 10. 验证方法

- 新增 `event pool initializes default security`、`mutex pool initializes default security` 和 `semaphore pool initializes default security` 测试。
- 每个测试验证 `security` 非空、指向 `security_storage`、普通用户对未授予访问位被拒绝、提升令牌通过。
- 使用 `builtin.is_test` 门控的 `TestHooks` 访问私有池分配函数，生产构建不暴露该钩子。
- 执行 `zig build test`。
- 后续可使用 REA 对应函数级分析确认 NT 6.1 的默认 DACL 掩码与副作用，并在多架构 QEMU 中验证打开路径。

## 11. 状态

- Fixed

## 12. 修复记录与二进制对照结论

已修复文件：

- `src/libs/ntdll.zig:214`
- `src/libs/ntdll.zig:255`
- `src/libs/ntdll.zig:288`
- `src/libs/ntdll.zig:325`
- `src/ntdll_sync_security_host_test.zig:1`
- `build.zig:848`

验证结果：`zig build test` 通过；`git diff --check` 通过。

与原始二进制对照结论：**未对照**。当前 REA 快照没有同步对象创建、默认安全初始化或相关 `Obp` 路径的函数级记录。结论限定为“已补齐源码级默认安全初始化并符合公开 NT 默认对象安全语义方向；与 Windows 7 镜像逐函数等价性待 REA 验证”。
