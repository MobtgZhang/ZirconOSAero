# Win32 / Native API 兼容性矩阵（骨架）

本表用于路线图 **C-T09**：随实现推进在 PR 中更新行，不依赖逆向 Windows 二进制。

| 模块        | 代表 API              | 状态     | 备注 |
|-------------|----------------------|----------|------|
| ntdll       | NtAllocateVirtualMemory | Partial | MEM_RESERVE/COMMIT、`#PF` 惰性提交 |
| ntdll       | NtUserGetMessage / PeekMessage | Partial | SSDT 0x58/0x59，内核消息泵桥接 |
| kernel32    | CreateFileA          | Partial | 见 VFS |
| user32      | GetMessage / DefWindowProc | Partial | SC_MOVE 模态环、DWM 广播消息 |
| gdi32       | TextOutA             | Partial | 位图字体；FreeType 为路线图 C-T05 |

**状态含义**：`Stub` 仅符号；`Partial` 有部分语义；`Done` 行为与公开文档一致且含测试；`Verified` 有 CI/回归覆盖。
