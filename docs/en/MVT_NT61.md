# NT 6.1 Minimum Verifiable Test (MVT) Index

> **Status labels** and **document ownership**: [DOCS_INDEX.md](../DOCS_INDEX.md) §STATUS_LEGEND and §维护约定.
> **Authority**: [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) and root [README.md](../../README.md).
> **PR gates**: [NT61_PR_GATES.md](NT61_PR_GATES.md).

## How to Run Verification

```bash
zig build test                    # Host-side unit tests (heap, pool, SSDT, IRP, VFS constants, etc.)
bash scripts/ci-qemu-smoke.sh     # x86_64 ZBM MBR serial smoke (requires local QEMU + build artifacts)
python3 tests/run_all.py          # Python test suite (boot combos, Multiboot2 headers, etc.)
```

GitHub Actions: `.github/workflows/ci.yml` (multi-arch `zig build kernel`, ZBM UEFI artifacts, `mkiso-uefi-zbm.sh`).

## Host Unit Tests (No QEMU Required)

| Capability | Command | Covered Module |
|-----------|---------|---------------|
| Kernel heap | `zig build test` → heap | `src/mm/heap.zig` |
| Pool allocator | same → pool | `src/mm/pool.zig` |
| Buddy system | same → buddy | `src/mm/buddy.zig` |
| Slab | same → slab | `src/mm/slab.zig` |
| PAGE_* → x86_64 PTE bits | same → **vm_nt_protect_pte_host** | `tests/vm_nt_protect_pte_host.zig` |
| TEB / KUSER x64 contract (offsets & VA) | same → **nt61_abi_layout_host** | `tests/nt61/abi_layout_host.zig`, `src/sdk/teb_nt61_x64.zig` |
| SSDT public indices | same → ssdt | `src/arch/x86_64/ssdt_nt61.zig` |
| User-mode `Ssdt` vs kernel `ssdt_nt61` subset parity | same → ssdt_stub_parity | `tests/ssdt_stub_parity.zig` |
| x64 vs x86 service number namespaces | same → ssdt_x64_x86_namespace | `tests/ssdt_x64_x86_namespace.zig` |
| WOW64 x86 service number subset | same → wow64_ssdt_x86 | `src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig` |
| WOW64 x86→x64 semantic alias mapping | same → wow64_x64_semantic_alias_host | `x64_semantic_alias.zig`, `wow64_x64_semantic_alias_host.zig` |
| WOW64 path/registry redirection | same → wow64_redirect_host | `src/subsystems/win32/wow64/redirect.zig` |
| Security token / DAC | same → se_token | `tests/se_token.zig`, `src/se/token.zig` |
| SMP atomic placeholder | same → smp_atomic_host | `tests/smp_atomic_host.zig` |
| Object handle table / path normalization / FIFO wait chain | same → object | `src/zircon_host_ob_test.zig` |
| IRP completion routines and device stack | same → io_irp_host | `tests/io_irp_host.zig` |
| PCIe ECAM offset | same → ecam_layout | `src/hal/x86_64/ecam_layout.zig` |
| HPET GCAP_ID decoding | same → hpet_id | `src/hal/x86_64/hpet_id.zig` |
| LPC `PortKind` ABI | same → lpc_portkind_host | `tests/lpc_portkind_host.zig` |
| LPC `handshake_version` (v2 anchors) | same → **lpc_handshake_version_host** | `tests/lpc_handshake_version_host.zig` |
| LPC two-PID queue round-trip | same → **lpc_two_pid_host** | `tests/lpc_two_pid_host.zig` |
| LPC `NtRequestWaitReplyPort` bad buffer NTSTATUS | same → **lpc_bad_pointer_host** | `tests/lpc_bad_pointer_host.zig` |
| `SystemVersionInformation` / `RTL_OSVERSIONINFOEXW` 284 bytes | same → **nt61_os_version_layout_host** | `tests/nt61/os_version_layout_host.zig` |
| ntdll/kernel32/user32 composite export ordering | same → **nt61_core_dll_abi_inventory_host** | `config/nt61_core_dll_abi_inventory.zig` |
| PE TLS/delay/bound policy failure codes | same → **pe_loader_policy_host** | `tests/pe_loader_policy_host.zig` |
| `SEC_IMAGE` + `IMAGE_SECTION_HEADER` 40 bytes | same → **pe64_nt61_host** | `sdk/pe64_nt61.zig` |
| fork subset: dup + read-only sub-mappings + CoW | same → **fork_cow_share_nt61_host** | `src/fork_cow_share_nt61_host.zig` |
| LoongArch64 ASID / fork / VAD (K1.4/K1.4b/K1.8) | same → **loongarch_nt61_mm_host** | `tests/host/loongarch_nt61_mm_host.zig` |
| GpuDevice / ramfb placeholder | same → gpu_device_host | `src/drivers/video/core/gpu_device.zig` |
| Win32k window skeleton | same → win32k_host | `src/subsystems/win32k/mod.zig` |
| Aero flag mapping (kernel ↔ userspace SurfaceFlags) | same → **aero_flag_mapping_host** | `config/aero_flag_mapping.zig` |
| COLORREF ↔ Kernel BGR (byte order) | same → **color_nt61_host** | `config/color_nt61.zig` |
| DWM message constants + WM_DWM* lParam packers | same → **dwm_messages_nt61_host** | `tests/nt61/dwm_messages_nt61.zig` |
| COMPOSITOR_TREE_SYNC_V1 / KERNEL_DWM_NOTIFY_V1 LPC payloads | same → **compositor_sync_nt61_host** | `config/compositor_sync_nt61.zig` |
| DWM public contract constants / struct layouts | same → **dwm_nt61_api_contract_host** | `src/config/dwm_nt61_api_contract.zig` |
| `dwmapi` export name table | same → **dwm_nt61_abi_inventory_host** | `config/dwm_nt61_abi_inventory.zig` |
| WOW64 `dwmapi` PE32 layout | same → **dwmapi_wow64_host** | `dwmapi_wow64.zig` |
| NTFS cluster size + hive roadmap anchors | same → **ntfs_hive_minimum_host** | `tests/nt61/ntfs_hive_minimum_host.zig` |
| Phase 4: window station LPC opcodes, WOW64 x86 LPC | same → **phase4_host_anchors** | `tests/nt61/phase4_host_anchors.zig` |
| LPC `get_message` thread id policy + `register_dwm_listener` v1 | same → **csr_lpc_policy_host** | `csr_lpc_policy.zig` |
| Composite Z-order two-pass model + cross-band SetWindowPos | same → **dwm_zorder_nt61_host** | `tests/nt61/dwm_zorder_nt61_host.zig` |
| Multi-monitor DPI formula | same → **multimon_dpi_nt61_host** | `tests/nt61/multimon_dpi_nt61_host.zig` |
| Aero Peek / Show Desktop hit | same → **taskbar_peek_hit_nt61_host** | `tests/nt61/taskbar_peek_hit_nt61_host.zig` |
| Start menu `needs_startmenu_repaint` not merged with `needs_full_scene` | same → **startmenu_paint_hint_nt61_host** | `tests/nt61/startmenu_paint_hint_nt61_host.zig` |
| `PeekMessage` `PM_REMOVE` / `PM_NOYIELD` | same → **msg_pm_semantics_host** | `msg_pm_semantics.zig` |
| Win32k: PM/LPC offsets / GDI ROP / Flip3D caps | same → **win32k_api_semantics_host** | `tests/nt61/win32k_api_semantics_host.zig` |
| GDI ROP implementation subset (BitBlt/StretchBlt/PatBlt) | same → **gdi_rop_contract_host** | `gdi_rop_contract.zig` |
| USB HID Boot mouse report parsing | same → **hid_boot_report_host** | `hid_boot_report.zig` |
| Compliance phrase scan | `bash scripts/verify-compliance.sh` | `scripts/verify-compliance.sh`; CI |
| Compliance scan | `bash scripts/check-docs-links.sh` | `scripts/check-docs-links.sh` |

## CI / Smoke Tests (QEMU or Build Artifacts)

| Capability | Step | Notes |
|-----------|------|-------|
| Build + ELF | `.github/workflows/ci.yml`; local `zig build install` | ReleaseSafe banner check |
| Minimal x64 PE (in-repo, `ExitProcess`) | `zig build minimal-pe-nt61` | Output: `zig-out/bin/zircon_nt61_minimal_pe.exe` |
| LoongArch64 SMP smoke (AP startup, ASID, multi-core scheduler) | `zig build run-qemu-smp-test` | Requires QEMU + LoongArch64 firmware + ESP image; serial checks `LoongArch SMP: AP%u initializing` |
| ZBM / headless boot | `bash scripts/ci-qemu-smoke.sh` | MBR disk, optional serial assertion |
| ACPI S5 / `NtShutdownSystem` | QEMU `-no-reboot` or serial check `ACPI PM:` | Requires **`PRIV_SHUTDOWN`** token; SSDT 0x40/0x41 |
| USB xHCI Boot keyboard | `-device qemu-xhci -device usb-kbd` | Serial: `USB: HID boot … proto=1` |
| VirtIO-GPU control queue + 2D transfer smoke | See [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) | Serial: `VirtIO-GPU: GET_DISPLAY_INFO + RESOURCE_CREATE_2D + TRANSFER_* scratch loop ok` |
| DWM box blur budget cost (`w×h×passes`) | `zig build test` → **dwm_blur_budget_host** | `config/dwm_blur_budget.zig` |
| aarch64 desktop-full compile gate | `.github/workflows/ci.yml` | `zig build kernel -Darch=aarch64 -Ddesktop-full=true` |

## Maintenance Rules

- Items marked "Partial" in the contract matrix must explain in PR whether the corresponding verification in this table or CI has been updated.
- Do **not** mark "done" in any document without adding a runnable verification.
- For Phase D (Win32 message pump and DWM/LPC): each landed semantic must add a column for the corresponding `zig build test` step or QEMU smoke command in this table.
