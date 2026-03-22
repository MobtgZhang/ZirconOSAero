# ZirconOS documentation

ZirconOS is an **NT-style hybrid microkernel operating system** implemented in Zig. The kernel provides minimal mechanisms (scheduling, virtual memory, IPC, interrupts, system calls); higher-level semantics live in user-mode services and subsystems, with a subset of Win32-compatible APIs.

**简体中文**：[cn/README.md](cn/README.md)

## Documentation index

| Document | Description |
|----------|-------------|
| [Architecture.md](en/Architecture.md) | Overall architecture: layering, design principles, object model, security |
| [Kernel.md](en/Kernel.md) | Kernel internals: scheduler, memory, interrupts, syscalls, IPC, Object Manager |
| [Boot.md](en/Boot.md) | Boot path: GRUB / ZBM / UEFI, kernel init phases (Phase 0–12) |
| [Servers.md](en/Servers.md) | System services: Process Server, Session Manager, LPC ports |
| [Subsystems.md](en/Subsystems.md) | Subsystems: Win32 (CMD/PowerShell/user32/gdi32), WOW64, POSIX |
| [BuildSystem.md](en/BuildSystem.md) | Build system: `build.conf`, Makefile, `build.zig`, `run.sh` |
| [Roadmap.md](en/Roadmap.md) | Roadmap: Phase 0–11 milestones, goals, non-goals, risks |

### Chinese (中文)

The same documents are available in Chinese under [`cn/`](cn/):

| 中文文档 | 说明 |
|----------|------|
| [Architecture.md](cn/Architecture.md) | 总体架构 |
| [Kernel.md](cn/Kernel.md) | 内核实现 |
| [Boot.md](cn/Boot.md) | 启动流程 |
| [Servers.md](cn/Servers.md) | 系统服务 |
| [Subsystems.md](cn/Subsystems.md) | 子系统 |
| [BuildSystem.md](cn/BuildSystem.md) | 构建系统 |
| [Roadmap.md](cn/Roadmap.md) | 路线图 |

## Repository layout (overview)

```
ZirconOS/
├── src/                   # Kernel and userland sources
├── boot/                  # Bootloader (GRUB, ZBM, UEFI)
├── link/                  # Per-architecture linker scripts
├── scripts/               # Build helpers (see scripts/README.md)
├── tests/                 # Test suite
├── assets/                # Screenshots and project artwork
├── docs/
│   ├── README.md          # This index (English)
│   ├── en/                # English documentation
│   └── cn/                # Chinese documentation
├── build.zig
├── Makefile
└── run.sh
```

## Tech stack

- **Language**: Zig (no libc dependency in the kernel build)
- **Architectures**: x86_64 (primary), aarch64, loongarch64, riscv64, mips64el
- **Boot**: BIOS (GRUB Multiboot2), UEFI, ZBM (in-tree boot manager)
- **Runtime**: QEMU for development and testing
