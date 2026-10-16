#!/usr/bin/env bash
set -euo pipefail

TREE="${1:?NT 6.1 文件树路径}"
BOOT_EFI="${2:?引导 EFI 路径}"
KERNEL="${3:?内核路径}"
BOOT_SUFFIX="${4:?引导文件后缀（X64/AA64/RISCV64/LOONGARCH64/ARM）}"

mkdir -p "${TREE}/EFI/Boot"
mkdir -p "${TREE}/EFI/Microsoft/Boot/Fonts"
mkdir -p "${TREE}/Windows/System32/config"
mkdir -p "${TREE}/Windows/System32/drivers"

cp "${BOOT_EFI}" "${TREE}/EFI/Boot/BOOT${BOOT_SUFFIX}.EFI"
cp "${BOOT_EFI}" "${TREE}/EFI/Microsoft/Boot/bootmgfw.efi"

cp "${KERNEL}" "${TREE}/Windows/System32/winload.efi"
cp "${KERNEL}" "${TREE}/Windows/System32/ntoskrnl.exe"
: > "${TREE}/EFI/Microsoft/Boot/BCD"
: > "${TREE}/EFI/Microsoft/Boot/bootmgr.efi"
: > "${TREE}/EFI/Microsoft/Boot/memtest.efi"
: > "${TREE}/Windows/System32/hal.dll"
: > "${TREE}/Windows/System32/kernel32.dll"
: > "${TREE}/Windows/System32/user32.dll"
: > "${TREE}/Windows/System32/advapi32.dll"
: > "${TREE}/Windows/System32/config/SYSTEM"
: > "${TREE}/Windows/System32/config/SOFTWARE"
: > "${TREE}/Windows/System32/config/SAM"
: > "${TREE}/Windows/System32/config/SECURITY"
: > "${TREE}/Windows/System32/config/DEFAULT"
: > "${TREE}/Windows/System32/drivers/acpi.sys"
: > "${TREE}/Windows/System32/drivers/bootvid.sys"
: > "${TREE}/Windows/System32/drivers/disk.sys"
: > "${TREE}/Windows/System32/drivers/partmgr.sys"
: > "${TREE}/Windows/System32/drivers/classpnp.sys"

for font in FreeMono.ttf FreeSans.ttf FreeSerif.ttf; do
    font_src="/usr/share/fonts/truetype/freefont/${font}"
    if [[ -f "${font_src}" ]]; then
        cp "${font_src}" "${TREE}/EFI/Microsoft/Boot/Fonts/${font}"
    fi
done
