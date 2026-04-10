# NT 6.1 Kernel PR Gate Checklist (K0, Clean-room)

> Aligned with [NT61_KERNEL_TODO.md](../cn/NT61_KERNEL_TODO.md) **Phase K0** and [AeroDesktopRuntime.md](AeroDesktopRuntime.md) (QEMU/display path). Self-check before merging kernel-related PRs. **Does not replace** human code review.

## K0.1 Contract Matrix

- [ ] Updated rows in [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) relevant to this PR (§0–§2, §8–§9, etc.) with new status or description.
- [ ] If adding a **Verified** capability, the test/CI column in the matrix points to a specific `zig build test` name or CI step.

## K0.2 Automated Verification

- [ ] New logic has `tests/` extension or existing host tests extended (see [MVT_NT61.md](MVT_NT61.md)).
- [ ] Local `zig build test` passes.
- [ ] If modifying Markdown under `docs/`: `bash scripts/check-docs-links.sh` (from repo root) passes.

## K0.3 Documentation Comments

- [ ] New or modified syscall, driver entry, IRP paths include **Microsoft Learn / WDK** or hardware spec links, and note any **simplifying assumptions** vs. full NT semantics.

## K0.4 Compliance

- [ ] `bash scripts/verify-compliance.sh` passes (matches CI Compliance step).
- [ ] No Windows/ReactOS/Wine source reference implementation.

## K0.5 Win32 / Subsystem Statements and Matrix (Any PR Touching the Following)

- [ ] If root [README.md](../../README.md) or [README_cn.md](../../README_cn.md) "Design Principles" paragraph or **Phase 0–11 feature matrix** rows (Status / Notes) are changed, the **same PR** must make the Chinese/English README rows semantically consistent and update [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) for relevant capabilities (if already in the matrix).
- [ ] If README, [Subsystems.md](Subsystems.md), [cn/Subsystems.md](../cn/Subsystems.md), or marketing "feature list" **expands** the completion statement for Win32, WOW64, ntdll, csrss, user32, gdi32, the **same PR** must update [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) and (if applicable) [API_COMPAT_MATRIX.md](../cn/API_COMPAT_MATRIX.md), and add reproducible verification in [MVT_NT61.md](MVT_NT61.md) or `tests/`, or explicitly keep `Stub`/`Partial`.
- [ ] Implementation and documentation references are limited to **Microsoft Learn, WDK, hardware specs, published ABI tables**; when behavioral details are insufficient, use experiments + documentation iteration, not non-whitelist reverse-engineered codebases.

**Phased roadmap**: [DOCS_INDEX.md](../DOCS_INDEX.md) §维护约定.

## Related Links

| Document | Purpose |
|----------|---------|
| [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) | Contract and status |
| [MVT_NT61.md](MVT_NT61.md) | Verification mapping |
| [PROCESS_NT61.md](PROCESS_NT61.md) | Phase flow |
| [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md) | Deferred items |
