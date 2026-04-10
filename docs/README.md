# ZirconOSAero documentation

ZirconOSAero is an **NT 6.1–target hybrid microkernel operating system** implemented in Zig. The kernel provides mechanisms (scheduling, virtual memory, IPC, interrupts, syscalls) **and** much **in-kernel Executive** code (objects, I/O, security, loaders — see [en/Architecture.md](en/Architecture.md)); **user-mode** today is mainly Process Server, SMSS, and Win32-facing libraries. Win32-compatible APIs are a **documented subset**, not retail Windows parity.

**简体中文**：[cn/README.md](cn/README.md)

**Full classified index** (every Markdown file under `docs/`): [DOCS_INDEX.md](DOCS_INDEX.md). **Status label legend and document ownership**: see [DOCS_INDEX.md](DOCS_INDEX.md) §STATUS_LEGEND and §维护约定.

**Reproducible builds / CI toolchain**: [REPRODUCE_BUILD.md](REPRODUCE_BUILD.md).

> **最后更新**：2026-04-10。文档更新原则：PR 涉及语义变更时必须同步更新对应文档；禁止仅凭文档勾选「完成」而不增加可运行验证。

NT 6.1–specific contracts, verification steps, and kernel work items are documented primarily in **Chinese** (`cn/`). English readers: [en/NT61_REFERENCE.md](en/NT61_REFERENCE.md) or the table below.

## Phase numbering (do not conflate)

| Name | Where | Meaning |
|------|-------|---------|
| **Kernel init Phase 0–12** | [en/Boot.md](en/Boot.md), [en/Kernel.md](en/Kernel.md), `src/main.zig` | Ordered bring-up steps inside the kernel |
| **Roadmap Phase 0–11** | [en/Roadmap.md](en/Roadmap.md), root `README.md` | Milestone **scope** headings — **not** “everything done” |
| **Phases D–G**, **desktop Phase 4** | [cn/README.md](cn/README.md) links | Separate trackers; **not** the same indices as 0–11 |

## NT 6.1 technical reference (authoritative in `cn/`)

| Topic | Document |
|-------|----------|
| Contract / status matrix | [cn/NT61_CONTRACT_MATRIX.md](cn/NT61_CONTRACT_MATRIX.md) |
| Verification (`zig build test`, paths) | [cn/MVT_NT61.md](cn/MVT_NT61.md) |
| Kernel backlog K0–K8 | [cn/NT61_KERNEL_TODO.md](cn/NT61_KERNEL_TODO.md) |
| PR gates + doc link check | [cn/NT61_PR_GATES.md](cn/NT61_PR_GATES.md) |
| Win32/Native API skeleton table | [cn/API_COMPAT_MATRIX.md](cn/API_COMPAT_MATRIX.md) |
| Long-term full API surface (not “done”) | [cn/NT61_FULL_API_BACKLOG.md](cn/NT61_FULL_API_BACKLOG.md) |
| Process / milestone flow | [cn/PROCESS_NT61.md](cn/PROCESS_NT61.md) |
| Implementation status snapshot | [cn/IMPLEMENTATION_STATUS_NT61.md](cn/IMPLEMENTATION_STATUS_NT61.md) |
| Syscall / SSDT | [cn/SyscallABI.md](cn/SyscallABI.md), [cn/SSDT_Roadmap.md](cn/SSDT_Roadmap.md) |
| Phases D–G, Phase 4 hardware | [cn/PHASE_D_WIN32_MSG_PUMP_DWM.md](cn/PHASE_D_WIN32_MSG_PUMP_DWM.md), [cn/PHASE_E_NATIVE_API.md](cn/PHASE_E_NATIVE_API.md), [cn/PHASE_F_PROCESS_CREATE.md](cn/PHASE_F_PROCESS_CREATE.md), [cn/PHASE_G_WOW64.md](cn/PHASE_G_WOW64.md), [cn/PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](cn/PHASE4_HARDWARE_SYSTEM_INTEGRATION.md) |

## Documentation index

| Document | Description |
|----------|-------------|
| [Architecture.md](en/Architecture.md) | Overall architecture: layering, design principles, object model, security |
| [Kernel.md](en/Kernel.md) | Kernel internals: scheduler, memory, interrupts, syscalls, IPC, Object Manager |
| [Boot.md](en/Boot.md) | Boot path: ZBM / UEFI, kernel init phases (Phase 0–12) |
| [Servers.md](en/Servers.md) | System services: Process Server, Session Manager, LPC ports |
| [Subsystems.md](en/Subsystems.md) | Subsystems: Win32 (CMD/user32/gdi32), WOW64, POSIX |
| [BuildSystem.md](en/BuildSystem.md) | Build system: primary **`zig build`**; optional `Makefile` / `build.conf` / `run.sh` wrappers |
| [Roadmap.md](en/Roadmap.md) | Roadmap: Phase 0–11 milestones, goals, non-goals, risks |
| [NT61_ShellIcons.md](en/NT61_ShellIcons.md) | Shell icons vs Win7, Zircon PE DLL, Win32 API notes |
| [BuiltinApps_NT61_Roadmap.md](en/BuiltinApps_NT61_Roadmap.md) | Built-in apps matrix, status, clean-room reference policy |
| [COPYRIGHT_AND_SOURCES.md](en/COPYRIGHT_AND_SOURCES.md) | Copyright boundaries and allowed knowledge sources (English) |
| [IMPLEMENTATION_STATUS_NT61.md](cn/IMPLEMENTATION_STATUS_NT61.md) | Honest MM/HAL, syscall, FS/PE status + verification commands (Chinese; technical terms in English where needed) |

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
| [NT61_ShellIcons.md](cn/NT61_ShellIcons.md) | NT 6.1 壳层图标与资源 DLL（中文主文档） |
| [BuiltinApps_NT61_Roadmap.md](cn/BuiltinApps_NT61_Roadmap.md) | 内置应用路线图（中文主文档） |
| [COPYRIGHT_AND_SOURCES.md](cn/COPYRIGHT_AND_SOURCES.md) | 版权边界与知识来源白名单（中文） |

## Repository layout (overview)

```
ZirconOSAero/
├── src/                   # Kernel and userland sources
├── boot/                  # ZBM (BIOS stage + UEFI)
├── link/                  # Per-architecture linker scripts
├── scripts/               # Build helpers (see scripts/README.md)
├── tests/                 # Test suite
├── assets/                # Screenshots and project artwork
├── docs/
│   ├── README.md          # This index (English)
│   ├── DOCS_INDEX.md      # Classified list + status legend + maintenance rules
│   ├── REPRODUCE_BUILD.md # Toolchain + release checklist
│   ├── en/                # English documentation
│   └── cn/                # Chinese documentation (NT61 depth)
├── build.zig
├── build.zig.zon
├── Makefile               # Optional convenience; CI uses zig build
└── run.sh
```

## Tech stack

- **Language**: Zig (no libc dependency in the kernel build)
- **Architectures**: x86_64 (primary), aarch64, loongarch64, riscv64; mips64el experimental
- **Boot**: ZBM only (BIOS/MBR chain and UEFI ESP); Multiboot2 handoff from ZBM to kernel
- **Runtime**: QEMU for development and testing
