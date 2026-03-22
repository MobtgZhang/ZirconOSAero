# ZirconOS 子系统

子系统负责提供应用兼容层 API，使不同类型的应用程序能在 ZirconOS 上运行。

## 1. 子系统总览

| 子系统 | 源码目录 | 状态 | 说明 |
|--------|----------|------|------|
| Native | — | 已实现 | ZirconOS 原生 API (ntdll) |
| Win32 | `src/subsystems/win32/` | 已实现 | kernel32 / user32 / gdi32 兼容层 |
| WOW64 | `src/subsystems/win32/wow64.zig` | 已实现 | 32 位 PE thunk + ABI 转换 |
| POSIX | — | 规划中 | libc / POSIX API 映射 |

### 调用层次

```
Win32 应用程序
    │
    ├─ kernel32.dll (Win32 Base API)
    │       │
    ├─ user32.dll (窗口/消息)
    │       │
    ├─ gdi32.dll (绘图)
    │       │
    └─ ntdll.dll (Native API)
            │
        syscall (int 0x80)
            │
        Microkernel
```

## 2. Native 子系统

Native 子系统提供 ZirconOS 原生 API，是所有其他子系统的基础。

### ntdll (src/libs/ntdll.zig)

NT Native API 的 ZirconOS 实现，所有系统调用的用户态入口。

| API 类别 | 示例函数 |
|----------|----------|
| 进程/线程 | NtCreateProcess, NtCreateThread, NtTerminateProcess |
| 文件 I/O | NtOpenFile, NtReadFile, NtWriteFile, NtClose |
| 内存 | NtAllocateVirtualMemory, NtMapViewOfSection |
| 同步 | NtCreateEvent, NtWaitForSingleObject |
| IPC | NtCreatePort, NtConnectPort, NtRequestWaitReplyPort |
| 注册表 | NtOpenKey, NtQueryValueKey, NtSetValueKey |
| 系统 | NtQuerySystemInformation |
| 调试 | DbgPrint |

## 3. Win32 子系统

Win32 子系统实现 Windows API 兼容层，是 ZirconOS 最复杂的子系统。

### 3.1 csrss — 子系统服务器 (subsystem.zig)

Win32 子系统的核心服务进程，类似 Windows 的 csrss.exe。

| 功能 | 说明 |
|------|------|
| 窗口站 | 管理 Window Station 对象 |
| 桌面 | 管理 Desktop 对象 |
| 进程注册 | 注册 Win32 进程到子系统 |
| GUI 分发 | 图形消息分发与路由 |

### 3.2 kernel32 — Win32 Base API (src/libs/kernel32.zig)

提供 Windows kernel32.dll 的 API 子集。

| API 类别 | 示例函数 |
|----------|----------|
| 进程 | CreateProcess, ExitProcess, GetCurrentProcessId |
| 文件 | CreateFile, ReadFile, WriteFile, FindFirstFile |
| 控制台 | WriteConsole, ReadConsole, SetConsoleTitle |
| 内存 | HeapAlloc, HeapFree, VirtualAlloc |
| 模块 | LoadLibrary, GetProcAddress, GetModuleHandle |
| 同步 | CreateEvent, WaitForSingleObject, CreateMutex |
| 环境 | GetEnvironmentVariable, GetCommandLine |

### 3.3 user32 — 窗口管理 API (user32.zig)

提供 Windows user32.dll 的 API 子集。

| 功能 | 说明 |
|------|------|
| 窗口管理 | CreateWindow, DestroyWindow, ShowWindow, MoveWindow |
| 窗口类 | RegisterClass, UnregisterClass |
| 消息队列 | GetMessage, PostMessage, DispatchMessage, PeekMessage |
| 输入处理 | 键盘和鼠标事件分发 |
| UI 原语 | MessageBox, DrawText |

### 3.4 gdi32 — 图形设备接口 (gdi32.zig)

提供 Windows gdi32.dll 的 API 子集。

| 功能 | 说明 |
|------|------|
| 设备上下文 | CreateDC, GetDC, ReleaseDC |
| 绘图原语 | LineTo, Rectangle, Ellipse, Polygon |
| 字体 | CreateFont, SelectObject, TextOut |
| 位图 | CreateBitmap, BitBlt, StretchBlt |
| GDI 对象 | Pen, Brush, Bitmap, Font, Region |

### 3.5 exec — 应用执行引擎 (exec.zig)

Win32 应用程序的加载和执行管理。

| 功能 | 说明 |
|------|------|
| PE 加载 | 加载 PE32/PE32+ 可执行文件 |
| DLL 绑定 | 解析导入表，绑定到 ntdll / kernel32 等 |
| 进程创建 | 创建进程对象、地址空间、初始线程 |
| 生命周期 | 管理进程从创建到终止的全过程 |

### 3.6 console — 控制台运行时 (console.zig)

Win32 控制台应用程序的运行时环境。

### 3.7 CMD — 命令提示符 (cmd.zig)

Windows 风格的命令行 Shell。

支持的命令：

| 命令 | 说明 |
|------|------|
| `dir` | 列出目录内容 |
| `cd` | 切换目录 |
| `set` | 查看/设置环境变量 |
| `ver` | 显示系统版本 |
| `systeminfo` | 显示系统信息 |
| `tasklist` | 显示进程列表 |
| `cls` | 清屏 |
| `echo` | 输出文本 |
| `type` | 显示文件内容 |
| `copy` / `del` / `mkdir` / `rmdir` | 文件操作 |

### 3.8 PowerShell (powershell.zig)

高级 Shell 环境，实现 PowerShell 风格的命令接口。

支持的 Cmdlet：

| Cmdlet | 说明 |
|--------|------|
| `Get-Process` | 获取进程列表 |
| `Get-ChildItem` | 列出目录内容 (ls/dir) |
| `Get-Service` | 获取服务列表 |
| `Get-Content` | 读取文件内容 |
| `Set-Location` | 切换目录 (cd) |
| `Write-Output` | 输出文本 |

## 4. WOW64 子系统 (wow64.zig)

WOW64 (Windows 32-bit on Windows 64-bit) 提供 32 位 Windows 应用的兼容运行环境。

### 工作原理

```
32 位 PE 应用程序
       │
   wow64.dll (thunk 层)
       │ 参数/结构体转换
   32 位 ntdll
       │ 32→64 位 syscall 翻译
   64 位内核
```

### 实现内容

| 组件 | 说明 |
|------|------|
| PE32 加载 | 加载 32 位 PE 可执行文件 |
| Syscall Thunking | 32 位系统调用翻译为 64 位 |
| 32 位 PEB/TEB | 为 32 位进程构建 32 位环境块 |
| 结构体转换 | 指针大小和结构体布局转换 |

## 5. POSIX 子系统 (规划中)

计划提供 POSIX / libc API 映射，使类 Unix 应用可以在 ZirconOS 上运行。

### 目标

- libc 基础函数 (open, read, write, fork, exec, wait, ...)
- POSIX 信号处理
- POSIX 线程 (pthread)
- 基础 Shell 工具 (bash, ls, cat, grep, ...)

## 6. 实现路线

```
 已完成                                              规划中
────┬────────┬───────────┬──────────┬───────────┬──────────
    │        │           │          │           │
 Native   Win32      Win32 GUI   WOW64      POSIX
 (ntdll)  Console    (user32/    (32-bit    (libc/
          (kernel32)  gdi32)     compat)    posix)
```

1. Native 子系统 (ntdll) — **已完成**
2. Win32 Console (kernel32 基础 API) — **已完成**
3. Win32 GUI (user32 / gdi32) — **已完成**
4. WOW64 (32 位兼容) — **已完成**
5. POSIX 最小集 — **规划中**
