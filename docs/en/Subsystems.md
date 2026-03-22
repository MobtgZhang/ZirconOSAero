# ZirconOS subsystems

Subsystems provide application compatibility layers so different app types can run on ZirconOS.

## 1. Overview

| Subsystem | Path | Status | Notes |
|-----------|------|--------|-------|
| Native | — | Done | ZirconOS native API (ntdll) |
| Win32 | `src/subsystems/win32/` | Done | kernel32 / user32 / gdi32 layer |
| WOW64 | `src/subsystems/win32/wow64.zig` | Done | 32-bit PE thunk + ABI glue |
| POSIX | — | Planned | libc/POSIX mapping |

### Call stack

```
Win32 application
    │
    ├─ kernel32.dll (Win32 base API)
    │       │
    ├─ user32.dll (windows/messages)
    │       │
    ├─ gdi32.dll (graphics)
    │       │
    └─ ntdll.dll (Native API)
            │
        syscall (int 0x80)
            │
        Microkernel
```

## 2. Native subsystem

The Native subsystem exposes ZirconOS native APIs and underpins everything else.

### ntdll (`src/libs/ntdll.zig`)

User-mode entry for system calls — NT Native API surface.

| Category | Examples |
|----------|----------|
| Process/thread | NtCreateProcess, NtCreateThread, NtTerminateProcess |
| File I/O | NtOpenFile, NtReadFile, NtWriteFile, NtClose |
| Memory | NtAllocateVirtualMemory, NtMapViewOfSection |
| Sync | NtCreateEvent, NtWaitForSingleObject |
| IPC | NtCreatePort, NtConnectPort, NtRequestWaitReplyPort |
| Registry | NtOpenKey, NtQueryValueKey, NtSetValueKey |
| System | NtQuerySystemInformation |
| Debug | DbgPrint |

## 3. Win32 subsystem

Largest subsystem — Windows API compatibility.

### 3.1 csrss — subsystem server (`subsystem.zig`)

Analogous to Windows csrss.exe.

| Feature | Role |
|---------|------|
| Window stations | Window station objects |
| Desktops | Desktop objects |
| Process registration | Register Win32 processes |
| GUI dispatch | Route graphics messages |

### 3.2 kernel32 — base API (`src/libs/kernel32.zig`)

Subset of kernel32.dll.

| Category | Examples |
|----------|----------|
| Process | CreateProcess, ExitProcess, GetCurrentProcessId |
| File | CreateFile, ReadFile, WriteFile, FindFirstFile |
| Console | WriteConsole, ReadConsole, SetConsoleTitle |
| Memory | HeapAlloc, HeapFree, VirtualAlloc |
| Module | LoadLibrary, GetProcAddress, GetModuleHandle |
| Sync | CreateEvent, WaitForSingleObject, CreateMutex |
| Environment | GetEnvironmentVariable, GetCommandLine |

### 3.3 user32 — windowing (`user32.zig`)

Subset of user32.dll.

| Feature | Role |
|---------|------|
| Windows | CreateWindow, DestroyWindow, ShowWindow, MoveWindow |
| Window classes | RegisterClass, UnregisterClass |
| Messages | GetMessage, PostMessage, DispatchMessage, PeekMessage |
| Input | Keyboard/mouse delivery |
| UI | MessageBox, DrawText |

### 3.4 gdi32 — GDI (`gdi32.zig`)

Subset of gdi32.dll.

| Feature | Role |
|---------|------|
| DC | CreateDC, GetDC, ReleaseDC |
| Drawing | LineTo, Rectangle, Ellipse, Polygon |
| Fonts | CreateFont, SelectObject, TextOut |
| Bitmaps | CreateBitmap, BitBlt, StretchBlt |
| GDI objects | Pen, brush, bitmap, font, region |

### 3.5 exec — execution engine (`exec.zig`)

Loads and runs Win32 apps.

| Feature | Role |
|---------|------|
| PE load | PE32/PE32+ executables |
| DLL binding | Import tables → ntdll/kernel32/… |
| Process creation | Address space, initial thread |
| Lifecycle | Create through exit |

### 3.6 console — console runtime (`console.zig`)

Runtime for Win32 console programs.

### 3.7 CMD — command shell (`cmd.zig`)

CMD-style shell.

| Command | Role |
|---------|------|
| `dir` | List directory |
| `cd` | Change directory |
| `set` | Environment variables |
| `ver` | Version |
| `systeminfo` | System info |
| `tasklist` | Process list |
| `cls` | Clear screen |
| `echo` | Print |
| `type` | Cat file |
| `copy` / `del` / `mkdir` / `rmdir` | File ops |

### 3.8 PowerShell (`powershell.zig`)

PowerShell-style cmdlets.

| Cmdlet | Role |
|--------|------|
| Get-Process | Processes |
| Get-ChildItem | Directory listing |
| Get-Service | Services |
| Get-Content | Read file |
| Set-Location | cd |
| Write-Output | Print |

## 4. WOW64 (`wow64.zig`)

Runs 32-bit Windows apps on 64-bit ZirconOS.

### Flow

```
32-bit PE app
       │
   wow64.dll (thunk layer)
       │ parameter/struct conversion
   32-bit ntdll
       │ 32→64 syscall translation
   64-bit kernel
```

### Pieces

| Piece | Role |
|-------|------|
| PE32 load | Load 32-bit PEs |
| Syscall thunking | Map 32-bit syscalls to 64-bit |
| 32-bit PEB/TEB | 32-bit environment blocks |
| Struct conversion | Pointer size and layout |

## 5. POSIX (planned)

libc/POSIX mapping for Unix-style apps.

### Targets

- libc basics (open, read, write, fork, exec, wait, …)
- POSIX signals
- pthreads
- Basic userland (bash, ls, cat, grep, …)

## 6. Implementation timeline

```
 Done                                              Planned
────┬────────┬───────────┬──────────┬───────────┬──────────
    │        │           │          │           │
 Native   Win32      Win32 GUI   WOW64      POSIX
 (ntdll)  Console    (user32/    (32-bit    (libc/
          (kernel32)  gdi32)     compat)    posix)
```

1. Native (ntdll) — **done**  
2. Win32 console (kernel32) — **done**  
3. Win32 GUI (user32/gdi32) — **done**  
4. WOW64 — **done**  
5. POSIX minimal set — **planned**  
