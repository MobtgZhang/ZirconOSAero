# NT 6.1 Shell Icons and ZirconOS Resource DLL

This document explains **Windows 7 public knowledge** on system icon storage, **ZirconOS original** asset correspondence, and **Win32-compatible** host-side resource DLL build. **Prohibited**: extracting or replicating bitmaps from Windows installation media (`shell32.dll` / `imageres.dll`). Clean-room compliance: [Assets.md](../cn/Assets.md).

## 1. Windows 7 Reference: Main Icon Resource Files

### 1.1 `%SystemRoot%\System32\shell32.dll`

One of the largest icon libraries (hundreds of icons): folders, drives, Computer, Recycle Bin, Control Panel items, network, printers, shortcut arrows, etc.

### 1.2 `%SystemRoot%\System32\imageres.dll`

Windows 7+ common high-resolution icon library (including 256×256 PNG): devices, media, system status (info/warning/error), users and security, network, etc.

### 1.3 Other DLL / EXE (Summary)

`imagehlp.dll`, `pifmgr.dll`, `moricons.dll`, `wmploc.dll`, `setupapi.dll`, `ddores.dll`, `accessibilitycpl.dll`, `netcenter.dll` / `netshell.dll` each have specialized icons. `explorer.exe`, `notepad.exe`, `calc.exe` etc. carry app icons.

### 1.4 How to View (Tools)

Resource Hacker, IcoFX, etc. can browse PE resources; `dll,-<id>` syntax in "Change Icon" dialog: see Microsoft Learn.

> Public documentation **does not provide** a complete per-index listing of `shell32`/`imageres`. ZirconOS uses **its own** resource numbering.

## 2. ZirconOS Strategy: Logical Correspondence to Microsoft, Content Not Corresponding to Binary

| Logical role | Repository build artifact | Notes |
|-------------|---------------------------|-------|
| Shell system icons (merged library) | `zircon_shell32_res.dll` | RT_ICON / RT_GROUP_ICON only; resource IDs **101–125** (see below) |
| LoongArch64 / "Windows for LoongArch64" placeholder | `zig-out/assets/loongarch64/win/System32/` | **Not PE**: Zig cannot yet produce `loongarch64-windows-gnu` COFF DLL (`UnsupportedCoffArchitecture`). This directory is **ICO tiles + `zircon_shell32_res.manifest.json`**; semantic alignment with `dll,-<id>` and PE machine **0x6264** (`IMAGE_FILE_MACHINE_LOONGARCH64`) for host/test manifest parsing |
| Optional split | `zircon_imageres_res.dll` | planned; currently merged into one DLL |
| Vector master source | `src/desktop/aero/resources/icons/*.svg` | see `DESIGN.md` in same directory |

Shell reference form matches Win7 (e.g., `zircon_shell32_res.dll,-101`), but **integer IDs differ** from Microsoft DLL; art is **LGPL/original**.

### 2.1 LoongArch PE and Community Progress (Compatibility Strategy)

- **PE32+ `.rsrc`** resource directory layout is **orthogonal** to COFF `Machine` field: as long as image is PE32+ (magic 0x20B) with valid resource directory, traversal by type/language ID works. The repository's **`.rsrc` parsing** (`pe_icon_resource.zig`) allows parsing for whitelisted COFF machine types: **AMD64 `0x8664`**, **ARM64 `0xAA64`**, **LoongArch32/64 `0x6232`/`0x6264`**, and UEFI-specified **RISC-V32/64/128 `0x5032`/`0x5064`/`0x5128`** (see [UEFI 2.10 — Debugger Support](https://uefi.org/specs/UEFI/2.10_A/18_Protocols_Debugger_Support.html)). Does **not** mean Zig can already produce `*-windows-gnu` resource DLL for these; toolchain gap similar to LoongArch.
- Community discussion **[LoongArch PE text relocations & Rust LoongArch64 UEFI Preview (#108)](https://github.com/loongson-community/discussions/issues/108)** focuses on **UEFI/experimental toolchains** for LoongArch PE and relocations, LLVM/Rust forks; **not equivalent** to "any Windows user-mode loader can load LoongArch DLL with `.rsrc` like x64". Zircon Tier 1 still delivers **`ico_bundle` + manifest**; Tier 2 depends on Zig/LLVM maturity for **`loongarch64-windows-gnu` COFF**.
- **Dual-track**: real PE DLL (x86_64) and LoongArch directory placeholder **semantically aligned** (same `shell_reference` / PE resource numbers); host can select ICO or PE by **`binary_form`** in manifest (see `pe_icon_loader.loadIconFromShellSystem32Dir`).

## 3. Win32 / Windows 7 API Compatibility Notes

The generated `zircon_shell32_res.dll` is a **valid PE DLL** with standard **`DllMain`** (`resources/win32/zircon_shell32_res_stub.c`). On Windows 7+ it supports:

- **`LoadLibraryW` / `LoadLibraryExW`** to load the module
- **`FindResource` / `LoadResource`** or upper **`LoadImage`**, **`ExtractIconEx`** to retrieve icons by **integer resource ID**

This is consistent with how the system's own `shell32.dll` "resource DLL" is used. Zircon kernel path still uses [`icons.zig`](../../src/drivers/video/desktop/icons.zig) embedded bitmaps + SVG manifest; PE parsing deferred to future user-mode.

## 4. Build Commands and Artifacts

| Step | Command | Dependencies |
|------|---------|-------------|
| SVG → ICO | `./scripts/build/build-aero-icons.sh` | `inkscape` or `rsvg-convert`; `magick` or `convert` |
| ICO + RC → DLL | `./scripts/build/build-zircon-icon-dll.sh` | MinGW `windres` + **`zig cc -target x86_64-windows-gnu`** |
| Integration (recommended) | `zig build aero-shell-icons-dll` | host: `windres` + **`zig cc -target x86_64-windows-gnu -shared`** (MinGW ABI) |
| LoongArch resource bundle (no DLL) | `zig build aero-shell-icons-la-bundle` | Installs 25 ICOs + **`zircon_shell32_res.manifest.json`** to **`zig-out/assets/loongarch64/win/System32/`** |
| Skip ICO regeneration | `zig build -Daero-skip-ico-build=true aero-shell-icons-dll` | reuse existing `resources/win32/ico/*.ico` |
| Tier 2 probe (optional) | `zig build aero-loongarch-windows-pe-probe` | expected to fail until upstream toolchain supports |

Artifacts: ICO in `src/desktop/aero/resources/win32/ico/*.ico`; DLL in `zig-out/assets/zircon_shell32_res.dll`; LoongArch bundle in `zig-out/assets/loongarch64/win/System32/*.ico` + manifest.

## 5. Related Source Code and PE Parsing (Clean-room)

- Kernel drawing: [`src/drivers/video/desktop/icons.zig`](../../src/drivers/video/desktop/icons.zig)
- Resource registration: [`src/desktop/aero/src/resource_loader.zig`](../../src/desktop/aero/src/resource_loader.zig)
- PE ID constants: [`src/desktop/aero/src/icon_resource_ids.zig`](../../src/desktop/aero/src/icon_resource_ids.zig)
- `.rsrc` by type/ID for raw bytes: [`src/desktop/aero/src/pe_icon_resource.zig`](../../src/desktop/aero/src/pe_icon_resource.zig)
- Disk read + RT_GROUP_ICON probe: [`src/desktop/aero/src/pe_icon_loader.zig`](../../src/desktop/aero/src/pe_icon_loader.zig)
- Manifest `binary_form`: [`shell_icons_manifest.zig`](../../src/desktop/aero/src/shell_icons_manifest.zig)

## 6. Relationship with Aero Rendering Document

Framebuffer and `IconId` mapping: [AeroRendering.md](../cn/AeroRendering.md).
