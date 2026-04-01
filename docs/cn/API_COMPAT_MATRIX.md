# Win32 / Native API 兼容性矩阵（骨架）

本表用于路线图 **C-T09**：随实现推进在 PR 中更新行，不依赖逆向 Windows 二进制。

**边界**：本表仅声明 **子集** 与 **Partial** 语义。完整 GDI（BitBlt ROP、字体光栅化、完整 DC 模型）、完整消息泵与 csrss 协议、完整 WOW64/SysWOW64 等均 **不** 由本表隐含「已完成」——见 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §5.1、§9.1–§9.2 与 [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md)。

**回归**：主机侧 `zig build test` 覆盖堆/池/SSDT/安全 DAC 镜像逻辑；Win32 API 行为测试随子系统以 `test` 块或 QEMU 场景追加。

| 模块        | 代表 API              | 状态     | 备注 |
|-------------|----------------------|----------|------|
| ntdll       | NtAllocateVirtualMemory | Partial | MEM_RESERVE/COMMIT、`#PF` 惰性提交 |
| ntdll       | NtUserGetMessage / PeekMessage | Partial | SSDT 0x58/0x59，内核消息泵桥接 |
| kernel32    | CreateFileA          | Partial | 见 VFS |
| user32      | GetMessage / DefWindowProc | Partial | SC_MOVE 模态环、DWM 广播消息 |
| gdi32       | TextOutA             | Partial | 位图字体；FreeType 为路线图 C-T05 |
| gdi32       | Rectangle / FillRect | Partial | 矩形填充子集；与 Aero 脏区合成见 `SOFTWARE_COMPOSITOR_WDDM.md` |

**状态含义**：`Stub` 仅符号；`Partial` 有部分语义；`Done` 行为与公开文档一致且含测试；`Verified` 有 CI/回归覆盖。
