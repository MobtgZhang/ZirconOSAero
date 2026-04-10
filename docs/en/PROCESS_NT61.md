# ZirconOSAero (NT 6.1 Style) — Strict Development Process

> **Phase naming**: see [cn/README.md](../cn/README.md) §Phase table. Phase 0–11 here are **Roadmap milestones**, **not** kernel init Phase 0–12.

This document defines the implementation order aligned with the **Windows 7 / NT 6.1** experience. All phases must be reproducibly buildable and verifiable before entering the next phase.

## Goals and Constraints

- **Kernel and architecture**: hybrid microkernel approach with NT-style subsystem layering; user-mode services and Win32 compatibility expand per milestone.
- **Boot**: **ZirconOSAero Boot Manager (ZBM) only** — BIOS/MBR chain and UEFI/GPT chain.
- **Visual**: default **Aero** desktop (`src/desktop/aero/`), consistent with Vista/7 glass, taskbar, and DWM composition direction.
- **Architecture**: `x86_64`, `aarch64`, `loongarch64`, `riscv64` (and upstream `mips64el`); UEFI built directly by Zig (x86_64/aarch64), LoongArch via GNU-EFI link path; **RISC-V UEFI** follows `build.zig` comments before Zig toolchain supports PE/COFF.

### Binary Compatibility Boundaries (Must Read)

- **Microsoft official Windows 7 user-mode binaries** target only **x86 / x86_64**. Other architectures are **same-name NT API subset + experimental shell** in this repository; no claim of loading Windows 7 official PE ecosystem.
- Contract granularity and "completion" are governed by [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md); **Partial / Stub** in README feature matrix means not Done.
- Capabilities explicitly not blocking kernel main milestones: [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) (WDDM, full Win32, WOW64, AML, etc.).
- **Realistic Win32 stack boundaries** (why full completion cannot be claimed): see [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) section "Win32 Compatibility Layer: Realistic Gaps and Project Boundaries". This repository delivers a **verifiable subset**, not bit-exact equivalence with commercial Windows user-mode **per API, per error code, per synchronization semantics**.

## Phase Breakdown (Must Follow Sequence)

### Phase 0 — Tooling and Baseline Build

- Lock Zig version; `zig build`, `make build` pass for primary target architectures.
- `build.conf`: `BOOTLOADER=zbm`, `DESKTOP=aero`.

### Phase 1 — Boot (ZBM)

- **MBR**: `boot/zbm/bios/` (mbr/vbr/stage2) and disk image built by `build-zbm-disk` boot into menu and load kernel on QEMU.
- **UEFI**: `boot/zbm/uefi/main.zig` (and LoongArch `main_loongarch64.zig`) builds `.efi`; `make build-esp` generates ESP.
- **ISO**: `scripts/build/mkiso-uefi-zbm.sh` + `xorriso` (embedded FAT ESP).

### Phase 2 — Kernel NT 6.1 Semantic Baseline

- Version and build tag externally present **NT 6.1** semantics (e.g. `RtlGetVersion`-style info, kernel log prefix); consistent with Phase 0–11 boot path documentation (see `docs/en/Kernel.md`).

### Phase 3 — Subsystems and User-Mode

- Object Manager, process/LPC, I/O, security descriptors implemented in dependency order; code layout per repository `src/`, behavior aligned with NT 6.1 public documentation.
- Sub-milestones: [ExecutivePhase3_Milestones.md](../cn/ExecutivePhase3_Milestones.md).

### Phase 4 — Aero Desktop and Composition

- Use `src/desktop/aero/` as mainline: compositor, theme loading, taskbar and Shell; resources maintained under `resources/`.
- **Spec**: [DesktopManagerSpec.md](DesktopManagerSpec.md) (Scheme B: kernel present + userspace compositing tree / Hit-test; `nt61_aero_defaults` aligned for glass parameters).
- **Verification**: [DesktopQA.md](../cn/DesktopQA.md), `scripts/desktop-qa.sh`.

### Phase 5 — Multi-Architecture Regression

- Per architecture: `make build ARCH=…`, `make build-esp` (if applicable) or `LOONGARCH64_QEMU_MODE=kernel` direct boot; record known limits (e.g. RISC-V UEFI linking).

## Verification Gates

Each phase must satisfy before merge:

1. Full build under default configuration.
2. Relevant `make test-*` or script tests pass (updated with repository).
3. Boot path description in this doc and `docs/en/Boot.md` consistent with implementation.
4. **Kernel-related PR**: cross-reference [NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md) when updating [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) rows; add [MVT_NT61.md](MVT_NT61.md) or `tests/` entries for new behaviors; run `bash scripts/verify-compliance.sh` before commit (matches CI).

## References

- Completion and contracts: [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md), [API_COMPAT_MATRIX.md](../cn/API_COMPAT_MATRIX.md)
- Kernel phased backlog: [NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md)
- English boot documentation: [Boot.md](Boot.md) (ZBM strategy only).
