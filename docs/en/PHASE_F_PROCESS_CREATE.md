# Phase F: User Process Creation Path (`NtCreateUserProcess`)

> **Naming note**: This "Phase F" is **user process creation path** (`NtCreateUserProcess` / SSDT **0xAA**); **≠** [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md) "Phase F — Integration". **Phase naming cross-reference**: [cn/README.md](../cn/README.md) §Phase table.

## References (Public Documentation)

- [NtCreateUserProcess](https://learn.microsoft.com/windows/win32/api/winternl/nf-winl-ntcreateuserprocess) (behavioral level; this repository's parameter block is **ZOA simplified ABI**)
- [PROCESS_BASIC_INFORMATION](https://learn.microsoft.com/windows/win32/api/winternl/ns-winternl-process_basic_information)
- This repo: [PROCESS_NT61.md](PROCESS_NT61.md), [SyscallABI.md](../cn/SyscallABI.md), [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)

## ZOA Subset: Implemented

| Stage | Description |
|-------|-------------|
| Syscall **0xAA** | `syscall_nt_extras.dispatchNtCreateUserProcess`: `R10` → `ZirconCreateUserProcessArgs` (see `syscall_abi.zig` comments) |
| Parameter probing | `probeUserMemory` for parameter block and output `HANDLE` slot; `UNICODE_STRING` image path → narrow-byte path |
| Process object | `process.createProcess`: address space, kuser, `parent_pid`, **token shallow copy** (parent `security_token`) |
| PE stub | `pe_loader.createProcessImage` + `resolveImports`; failures return `STATUS_ENTRYPOINT_NOT_FOUND` (0xC0000139) etc. |
| Initial thread | `scheduler.createThread(entry, child.pid)`; `PsThreadObject` for thread handle |
| Handles | Parent process handle table: `ObjectType.process` / `.thread` |
| `NtCreateProcess` / `NtCreateProcessEx` | Old stubs only allocate process slot; **do not** map image; distinguished from this path in `ntdll.zig` comments |

## Parameter Block `ZirconCreateUserProcessArgs` (User-Mode Layout)

```
offset 0:  image_path_unicode  u64   UNICODE_STRING*
         process_handle_out    u64   PHANDLE (writable)
         thread_handle_out     u64   PHANDLE (writable; 0 = don't want thread handle)
         creation_flags        u32   reserved/passthrough (currently ignored)
         reserved              u32
```

## Known Gaps (Honest Boundary)

- **Image and CR3**: `pe_loader.loadImage` is a global `LoadedImage` metadata stub; **does not** map sections into child process `AddressSpace`; scheduler thread entry is **RIP from metadata**, different from real NT user-mode execution model.
- **PEB/TEB (64-bit Nt path)**: child process `Process.peb_address` is still **0** (user VA mapping not wired); `NtQueryInformationProcess`'s `peb_base_address` consistent with this.
- **csrss / Subsystem**: no full subsystem handshake, no job objects, no debug objects.
- **WOW64 demo process**: `wow64.createWow64Process` gets real `AddressSpace` via `process.createProcess`; on x86_64 maps **PEB32/TEB32** user pages and writes structs (default VA: see `wow64/types.zig`). **Full SysWOW64 / section mapping into child process** is still **Partial**; acceptance: [PHASE_G_WOW64.md](PHASE_G_WOW64.md).

## Acceptance NTSTATUS (Excerpt)

| Value | Meaning |
|-------|---------|
| `STATUS_SUCCESS` | Subset creation succeeded |
| `STATUS_INVALID_PARAMETER` | Invalid parameter block / path |
| `STATUS_ACCESS_VIOLATION` | Probe failure |
| `STATUS_NO_MEMORY` | Process/image/thread slot exhausted |
| `STATUS_ENTRYPOINT_NOT_FOUND` | Not all imports resolved (0xC0000139) |
| `STATUS_INSUFFICIENT_RESOURCES` | Handle table full etc. |

## Verification

- **F-VERIFY**: `ssdt.NtCreateUserProcess` in `syscall.zig` → `syscall_nt_extras.dispatchNtCreateUserProcess`; rollback and NTSTATUS per this doc's "ZOA subset" table.
- `zig build test` (including `ssdt_stub_parity`, `NtCreateUserProcess` number consistent with `ntdll_syscall_win64`)
- `bash scripts/verify-compliance.sh`

**F-DEEP (optional PR)**: section mapping into child `AddressSpace`, user VA PEB/TEB with [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §9 and [PHASE_G_WOW64.md](PHASE_G_WOW64.md) honestly registered — if not done, keep matrix **Partial**.
