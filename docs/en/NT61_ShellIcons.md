# NT 6.1 shell icons and ZirconOS resource DLL

This document maps **public Windows 7 knowledge** about where system icons live to **ZirconOS-original** artwork, and describes a **Win32-compatible** host-built PE DLL.  
**Do not** extract or replicate bitmaps from Microsoft `shell32.dll` / `imageres.dll`. See [Assets.md](../cn/Assets.md) (Chinese) / project rules `zig-nt61-copyright-safety-testing.mdc`.

## 1. Windows 7 reference (informational)

- **`shell32.dll`**: large system icon set (folders, drives, recycle bin, control panel, network, printers, overlays, etc.).
- **`imageres.dll`**: high-resolution icons (often including 256×256 PNG) for devices, media, status glyphs, security, networking.
- Other modules (`setupapi.dll`, `ddores.dll`, `wmploc.dll`, …) and various **EXE** files hold additional icons. Public docs do **not** publish a complete index of every resource ID.

Tools such as Resource Hacker can browse PE resources. Shell syntax `module.dll,-<id>` is documented under Microsoft Learn (offline: `desktop-src/shell/...`).

## 2. ZirconOS policy

| Role | Artifact | Notes |
|------|----------|-------|
| Combined shell icon library | `zircon_shell32_res.dll` | `RT_ICON` / `RT_GROUP_ICON` only; IDs **101–125** (see `src/desktop/aero/resources/win32/ICON_RESOURCE_IDS.md`) |
| LoongArch64 / “Windows for LoongArch64” stand-in | `zig-out/assets/loongarch64/win/System32/` | **Not a PE**: Zig cannot emit `loongarch64-windows-gnu` COFF DLLs yet (`UnsupportedCoffArchitecture`). This tree is **flat `.ico` files + `zircon_shell32_res.manifest.json`**, carrying the same logical `dll,-<id>` IDs and **PE machine 0x6264** (`IMAGE_FILE_MACHINE_LOONGARCH64`) for host-side tooling. |
| Source vectors | `src/desktop/aero/resources/icons/*.svg` | Canonical art; `DESIGN.md` |

IDs are **Zircon-owned**; visuals are **LGPL / in-tree original**, not binary-compatible with Microsoft’s resource numbering.

### 2.1 LoongArch PE and community status (compatibility)

- PE32+ **`.rsrc`** layout is orthogonal to the COFF **`Machine`** field: if the image is **PE32+ (magic 0x20B)** and the resource directory is valid, IDs can be walked. **[`pe_icon_resource.zig`](../../src/desktop/aero/src/pe_icon_resource.zig)** whitelists **`0x8664` (AMD64)**, **`0xAA64` (ARM64)**, **`0x6232`/`0x6264` (LoongArch32/64)**, and UEFI’s **RISC-V32/64/128 `0x5032`/`0x5064`/`0x5128`** (see [UEFI 2.10 — Debugger Support](https://uefi.org/specs/UEFI/2.10_A/18_Protocols_Debugger_Support.html)). This does **not** mean Zig already ships working `aarch64-windows-gnu` / `riscv64-windows-gnu` resource DLLs; toolchain gaps mirror LoongArch.
- **[loongson-community/discussions#108](https://github.com/loongson-community/discussions/issues/108)** (LoongArch PE relocations, Rust LoongArch64 UEFI preview, LLVM/Rust forks) is about **UEFI / experimental toolchains**, **not** a guarantee that Windows user-mode loaders behave like x64 for LoongArch resource DLLs. **Tier 1** remains the **`ico_bundle` + manifest** tree; **Tier 2** depends on mature **`loongarch64-windows-gnu` COFF** in Zig/LLVM. Use **`zig build aero-loongarch-windows-pe-probe`** to probe; it is **expected to fail** until upstream support lands.
- **Dual track**: the real x86_64 PE DLL and the LoongArch directory bundle stay **semantically aligned** (same `shell_reference` / PE ids). Hosts can branch on manifest **`binary_form`** (ICO vs PE) via **`loadIconFromShellSystem32Dir`** in [`pe_icon_loader.zig`](../../src/desktop/aero/src/pe_icon_loader.zig).

## 3. Windows 7 / Win32 API compatibility

The generated DLL is a normal **PE DLL** with a minimal **`DllMain`** (`zircon_shell32_res_stub.c`). On Windows 7+ it can be loaded with **`LoadLibrary`/`LoadLibraryEx`** and icons retrieved via **`LoadImage`**, **`ExtractIconEx`**, or raw **`FindResource`/`LoadResource`**, using the numeric IDs **101–125**.

This matches how **resource-only** system DLLs are consumed; it does **not** copy Microsoft exports or proprietary code.

Design guidance for `.ico` sizes: `desktop-src/uxguide/vis-icons.md`.

## 4. IDs and files

Logical **`IconId` 1–25** align with PE **101–125** and ICO basenames — see `src/desktop/aero/resources/icons/README.md`. In Zig, the member for ID 25 is **`err`** (`error` is reserved); the file remains `error.svg`.

## 5. Build

| Step | Command | Tooling |
|------|---------|---------|
| SVG → ICO | `./scripts/build/build-aero-icons.sh` | Inkscape or `rsvg-convert`; ImageMagick |
| ICO + RC → DLL | `./scripts/build/build-zircon-icon-dll.sh` | MinGW `windres` + **`zig cc -target x86_64-windows-gnu`**; optional `SKIP_AERO_ICO_BUILD=1` |
| Via Zig | `zig build aero-shell-icons-dll` | `windres` + **`zig cc -target x86_64-windows-gnu -shared`**; installs to `zig-out/assets/` |
| LoongArch bundle (no DLL) | `zig build aero-shell-icons-la-bundle` | Installs **25 ICOs** + **`zircon_shell32_res.manifest.json`** under **`zig-out/assets/loongarch64/win/System32/`** (same ICO prerequisites as the DLL step, or `-Daero-skip-ico-build=true`). |
| Skip ICO regen | `zig build -Daero-skip-ico-build=true aero-shell-icons-dll` | Reuse existing `ico/*.ico` |
| Custom windres | `zig build -Daero-windres=... aero-shell-icons-dll` | Default `x86_64-w64-mingw32-windres` |
| Tier 2 probe (optional) | `zig build aero-loongarch-windows-pe-probe` | Runs `scripts/build/probe-loongarch-windows-gnu-shared.sh`; **expected to fail** until the toolchain supports LoongArch COFF DLLs (e.g. `UnsupportedCoffArchitecture`). CI may use `continue-on-error`. |
| Reserved option | `-Daero-la-pe-dll` | **Placeholder** for a future LoongArch PE resource-DLL build path (default false; use `aero-shell-icons-la-bundle` today). |

Outputs: `src/desktop/aero/resources/win32/ico/*.ico` (gitignored), `zig-out/assets/zircon_shell32_res.dll` (under ignored `zig-out/`), and optionally **`zig-out/assets/loongarch64/win/System32/`** (manifest lists `logical_id`, `pe_resource_id`, `shell_reference`, `pe_machine`, `binary_form: ico_bundle`; aligned with `ICON_RESOURCE_IDS.md`).

## 6. Kernel vs host

The kernel framebuffer path still uses embedded 16×16 fallbacks in `src/drivers/video/icons.zig` plus SVG registration in `resource_loader.zig`. **`pe_icon_resource.zig`** implements PE32+ `.rsrc` lookup from raw bytes (MS PE/COFF spec only). **`pe_icon_loader.loadIconResource`** reads a file on the host and locates `RT_GROUP_ICON` without calling Win32 APIs; pixel decode is still TODO. Manifest **`binary_form`** is parsed in **`shell_icons_manifest.zig`**; **`loadIconFromShellSystem32Dir`** selects ICO bundle vs PE for a `System32`-style directory.

## 7. See also (Chinese)

Detailed tables and roadmap gaps: [NT61_ShellIcons.md](../cn/NT61_ShellIcons.md). Aero drawing notes: [AeroRendering.md](../cn/AeroRendering.md).
