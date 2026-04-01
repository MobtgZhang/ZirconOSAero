#!/usr/bin/env bash
set -euo pipefail

# ZirconOSAero (NT 6.1 style) — Build & Run Script
# Thin wrapper around Makefile. All build logic lives in Makefile + build.conf.
#
# Usage:
#   ./run.sh                          Build & run per build.conf
#   ./run.sh run                      Same as above
#   ./run.sh build                    Build kernel only
#   ./run.sh run DESKTOP=aero         Override desktop theme
#   ./run.sh run-qemu-sdl             x86 QEMU with SDL display (vs default GTK)
#   ./run.sh run-qemu-zoom-fit        GTK scale guest FB to window (vs default 1:1)
#   ./run.sh run BOOT_METHOD=mbr BOOTLOADER=zbm
#   ./run.sh configure                Interactive config wizard
#   ./run.sh test                     Run all tests
#   ./run.sh help                     Show all targets

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

info()  { echo -e "\033[1;32m[ZirconOSAero]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

check_make() {
    command -v make >/dev/null 2>&1 || error "make not found (apt install build-essential)"
}

# Parse arguments: first arg is the make target, remaining are VAR=VALUE overrides
TARGET="${1:-run}"
shift 2>/dev/null || true

MAKE_ARGS=()
for arg in "$@"; do
    MAKE_ARGS+=("$arg")
done

# Map legacy commands to new make targets for backward compatibility
case "$TARGET" in
    build)                  TARGET="build" ;;
    build-release)          TARGET="build-release" ;;
    build-zbm)              TARGET="build-zbm-bios" ;;
    build-zbm-disk)         TARGET="build-zbm-disk" ;;
    build-desktop)
        theme="${1:-}"
        shift 2>/dev/null || true
        if [ -n "$theme" ]; then
            MAKE_ARGS+=("DESKTOP=$theme")
        fi
        TARGET="build-desktop"
        ;;
    iso)                    TARGET="iso-debug" ;;
    iso-debug)              TARGET="iso-debug" ;;
    iso-release)            TARGET="iso-release" ;;
    run)                    TARGET="run" ;;
    run-release)            TARGET="run" ; MAKE_ARGS+=("OPTIMIZE=ReleaseSafe") ;;
    run-debug)              TARGET="run-debug" ;;
    run-bios)               TARGET="run" ; MAKE_ARGS+=("BOOT_METHOD=mbr" "BOOTLOADER=zbm") ;;
    run-uefi)               TARGET="run" ; MAKE_ARGS+=("BOOT_METHOD=uefi" "BOOTLOADER=zbm") ;;
    run-uefi-direct)        TARGET="run" ; MAKE_ARGS+=("BOOT_METHOD=uefi" "BOOTLOADER=zbm") ;;
    run-zbm)                TARGET="run" ; MAKE_ARGS+=("BOOT_METHOD=mbr" "BOOTLOADER=zbm") ;;
    run-zbm-uefi)           TARGET="run" ; MAKE_ARGS+=("BOOT_METHOD=uefi" "BOOTLOADER=zbm") ;;
    run-desktop)
        theme="${1:-}"
        shift 2>/dev/null || true
        if [ -n "$theme" ]; then
            MAKE_ARGS+=("DESKTOP=$theme")
        fi
        TARGET="run"
        ;;
    run-desktop-uefi)
        theme="${1:-}"
        shift 2>/dev/null || true
        if [ -n "$theme" ]; then
            MAKE_ARGS+=("DESKTOP=$theme")
        fi
        MAKE_ARGS+=("BOOT_METHOD=uefi" "BOOTLOADER=zbm")
        TARGET="run"
        ;;
    run-qemu-1to1)          TARGET="run-qemu-1to1" ;;
    run-qemu-zoom-fit)      TARGET="run-qemu-zoom-fit" ;;
    run-qemu-sdl)           TARGET="run-qemu-sdl" ;;
    run-aarch64)            TARGET="run" ; MAKE_ARGS+=("ARCH=aarch64") ;;
    run-uefi-aarch64)       TARGET="run" ; MAKE_ARGS+=("ARCH=aarch64" "BOOT_METHOD=uefi") ;;
    configure)              TARGET="configure" ;;
    show-config)            TARGET="show-config" ;;
    test)                   TARGET="test" ;;
    test-kernel)            TARGET="test-kernel" ;;
    test-config)            TARGET="test-config" ;;
    test-boot)              TARGET="test-boot" ;;
    clean)                  TARGET="clean" ;;
    help|--help|-h)         TARGET="help" ;;
    *)                      error "Unknown command: $TARGET (try './run.sh help')" ;;
esac

# Also forward environment variables as make overrides
[ -n "${ARCH:-}" ]        && MAKE_ARGS+=("ARCH=$ARCH")
[ -n "${DEBUG:-}" ]       && MAKE_ARGS+=("DEBUG_LOG=$DEBUG")
[ -n "${ENABLE_IDT:-}" ]  && MAKE_ARGS+=("ENABLE_IDT=$ENABLE_IDT")
[ -n "${QEMU_MEM:-}" ]    && MAKE_ARGS+=("QEMU_MEM=$QEMU_MEM")
[ -n "${QEMU_DISPLAY_BACKEND:-}" ] && MAKE_ARGS+=("QEMU_DISPLAY_BACKEND=$QEMU_DISPLAY_BACKEND")
[ -n "${DESKTOP:-}" ]     && MAKE_ARGS+=("DESKTOP=$DESKTOP")

check_make
exec make -C "$ROOT_DIR" "$TARGET" "${MAKE_ARGS[@]}"
