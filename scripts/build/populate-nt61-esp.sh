#!/usr/bin/env bash
set -euo pipefail

TREE="${1:?NT 6.1 文件树路径}"
BOOT_EFI="${2:?引导 EFI 路径}"
KERNEL="${3:?内核路径}"
BOOT_SUFFIX="${4:?引导文件后缀（X64/AA64/RISCV64/LOONGARCH64/ARM）}"
WINLOAD_EFI="${WINLOAD_EFI:-${BOOT_EFI}}"

mkdir -p "${TREE}/EFI/Boot"
mkdir -p "${TREE}/EFI/Microsoft/Boot/Fonts"
mkdir -p "${TREE}/Windows/System32/config"
mkdir -p "${TREE}/Windows/System32/drivers"

cp "${BOOT_EFI}" "${TREE}/EFI/Boot/BOOT${BOOT_SUFFIX}.EFI"
cp "${BOOT_EFI}" "${TREE}/EFI/Microsoft/Boot/bootmgfw.efi"

cp "${WINLOAD_EFI}" "${TREE}/Windows/System32/winload.efi"
: > "${TREE}/EFI/Microsoft/Boot/BCD"
: > "${TREE}/EFI/Microsoft/Boot/bootmgr.efi"
: > "${TREE}/EFI/Microsoft/Boot/memtest.efi"
: > "${TREE}/Windows/System32/hal.dll"

if command -v nm >/dev/null 2>&1 && command -v objcopy >/dev/null 2>&1; then
    KERNEL_MAIN=$(nm "${KERNEL}" 2>/dev/null | awk '$3 == "kernel_main" { print "0x" $1 }')
    KERNEL_MAIN="${KERNEL_MAIN%%$'\n'*}"
    if [[ "${KERNEL_MAIN}" =~ ^0x[0-9a-fA-F]+$ ]]; then
        bash "$(dirname "$0")/mkpe-from-elf.sh" \
            "${KERNEL}" \
            "${TREE}/Windows/System32/ntoskrnl.exe" \
            "${KERNEL_MAIN}" \
            "0x04000000"
    else
        cp "${KERNEL}" "${TREE}/Windows/System32/ntoskrnl.exe"
    fi
else
    cp "${KERNEL}" "${TREE}/Windows/System32/ntoskrnl.exe"
fi
: > "${TREE}/Windows/System32/kernel32.dll"
: > "${TREE}/Windows/System32/user32.dll"
: > "${TREE}/Windows/System32/advapi32.dll"
: > "${TREE}/Windows/System32/ntdll.dll"
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

if command -v zig >/dev/null 2>&1; then
    STUB_SRC="$(dirname "$0")/../../tools/nt61_pe_stubs"
    zig cc -target x86_64-windows-gnu -shared -nostdlib -o "${TREE}/Windows/System32/hal.dll" \
        "${STUB_SRC}/hal.c" -Wl,-e,DllMain -Wl,--image-base=0x10000000
    driver_index=0
    for driver in acpi.sys bootvid.sys disk.sys partmgr.sys classpnp.sys; do
        driver_index=$((driver_index + 1))
        driver_base=$((0x11000000 + (driver_index - 1) * 0x01000000))
        zig cc -target x86_64-windows-gnu -shared -nostdlib -o "${TREE}/Windows/System32/drivers/${driver}" \
            "${STUB_SRC}/boot_driver.c" -Wl,-e,DriverEntry -Wl,--image-base="${driver_base}" -Wl,--export-all-symbols
    done

    build_user_pe() {
        local name="$1"
        local base="$2"
        local source="$3"
        local process_name="${4:-}"
        local process_flags=()
        if [[ -n "${process_name}" ]]; then
            process_flags=(-DPROCESS_NAME="\"${process_name}\"")
        fi
        zig cc -target x86_64-windows-gnu -nostdlib -fno-sanitize=undefined \
            -o "${TREE}/Windows/System32/${name}" \
            "${STUB_SRC}/${source}" \
            -Wl,-e,NtProcessStart \
            -Wl,--image-base="${base}" \
            "${process_flags[@]}"
    }

    build_user_pe smss.exe 0x12000000 user_process.c smss.exe
    build_user_pe wininit.exe 0x12100000 user_process.c wininit.exe
    build_user_pe services.exe 0x12200000 user_process.c services.exe
    build_user_pe lsass.exe 0x12300000 user_process.c lsass.exe
    build_user_pe winlogon.exe 0x12400000 user_process.c winlogon.exe
    build_user_pe userinit.exe 0x12500000 user_process.c userinit.exe
    build_user_pe cmd.exe 0x12600000 user_cmd.c
fi

for font in FreeMono.ttf FreeSans.ttf FreeSerif.ttf; do
    font_src="/usr/share/fonts/truetype/freefont/${font}"
    if [[ -f "${font_src}" ]]; then
        cp "${font_src}" "${TREE}/EFI/Microsoft/Boot/Fonts/${font}"
    fi
done
