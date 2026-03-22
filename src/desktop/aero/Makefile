# ZirconOS Aero Desktop — Makefile
# DWM-composited Glass Desktop Theme (NT 6.1 style)
#
# Default: UEFI boot with Aero desktop
# Requires: zig, qemu-system-x86_64, OVMF firmware, mtools

.PHONY: all build build-lib build-exe test run run-uefi run-bios \
	resources fonts iso esp clean help

# ── Configuration ──

VERSION      := 1.1.0
ARCH         ?= x86_64
OPTIMIZE     ?= Debug
QEMU_MEM     ?= 512M
RESOLUTION   ?= 1024x768x32

ROOT_DIR     := $(shell cd ../.. && pwd)
AERO_DIR     := $(shell pwd)
FONTS_DIR    := $(ROOT_DIR)/src/fonts
BUILD_DIR    := $(ROOT_DIR)/build
TMP_DIR      := $(BUILD_DIR)/tmp
RELEASE_DIR  := $(BUILD_DIR)/release
KERNEL_ELF   := $(TMP_DIR)/kernel-prefix/bin/kernel
ISO          := $(RELEASE_DIR)/zirconos-$(VERSION)-$(ARCH).iso
ESP_IMG      := $(BUILD_DIR)/esp-$(ARCH).img

# OVMF UEFI firmware paths
OVMF_CODE    ?= /usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS    ?= /usr/share/OVMF/OVMF_VARS_4M.fd

# ── Default target: build + UEFI run ──

all: run-uefi

help:
	@echo "ZirconOS Aero v$(VERSION) — DWM Glass Desktop"
	@echo ""
	@echo "Build:"
	@echo "  make build         Build Aero theme library + kernel"
	@echo "  make build-lib     Build Aero static library only"
	@echo "  make build-exe     Build Aero standalone executable"
	@echo "  make test          Run unit tests"
	@echo "  make iso           Build UEFI ISO via root Makefile (ZBM, no GRUB)"
	@echo "  make esp           Build UEFI ESP image"
	@echo ""
	@echo "Run (QEMU):"
	@echo "  make run           Run Aero desktop via UEFI (default)"
	@echo "  make run-uefi      Run Aero desktop via UEFI/OVMF"
	@echo "  make run-bios      Run via root ZBM MBR disk (BOOT_METHOD=mbr)"
	@echo ""
	@echo "Resources:"
	@echo "  make resources     Validate and list Aero resources"
	@echo "  make fonts         Fetch fonts (ZirconOSFonts)"
	@echo ""
	@echo "  make clean         Remove build artifacts"
	@echo ""
	@echo "Options:"
	@echo "  ARCH=x86_64        Target architecture"
	@echo "  OPTIMIZE=Debug     Zig optimize mode (Debug/ReleaseSafe/ReleaseFast)"
	@echo "  QEMU_MEM=512M      QEMU memory size"
	@echo "  RESOLUTION=1024x768x32  Display resolution"

# ── Build Targets ──

build: build-kernel
	@echo "[AERO] Build complete (kernel + Aero desktop)"

build-lib:
	@echo "[AERO] Building Aero static library..."
	cd $(AERO_DIR) && zig build -Doptimize=$(OPTIMIZE)
	@echo "[AERO] Library built: zig-out/lib/libZirconOSAero.a"

build-exe:
	@echo "[AERO] Building Aero standalone executable..."
	cd $(AERO_DIR) && zig build -Doptimize=$(OPTIMIZE)
	@echo "[AERO] Executable built: zig-out/bin/ZirconOSAero"

test:
	@echo "[AERO] Running unit tests..."
	cd $(AERO_DIR) && zig build test
	@echo "[AERO] All tests passed"

build-kernel:
	@echo "[AERO] Building kernel with Aero desktop (arch=$(ARCH), optimize=$(OPTIMIZE))..."
	@mkdir -p $(TMP_DIR)/kernel-prefix $(TMP_DIR)/zig-cache
	cd $(ROOT_DIR) && zig build \
		-Doptimize=$(OPTIMIZE) \
		-Darch=$(ARCH) \
		-Ddebug=true \
		-Denable_idt=true \
		--cache-dir $(TMP_DIR)/zig-cache \
		--prefix $(TMP_DIR)/kernel-prefix
	@echo "[AERO] Kernel built: $(KERNEL_ELF)"

# ── ISO / ESP ──

iso: build-kernel
	@echo "[AERO] Delegating ISO build to project root (ZBM UEFI ISO)..."
	cd $(ROOT_DIR) && $(MAKE) iso ARCH=$(ARCH) DESKTOP=aero OPTIMIZE=$(OPTIMIZE)

esp: build-kernel
	@echo "[AERO] Delegating ESP build to project root..."
	cd $(ROOT_DIR) && $(MAKE) build-esp ARCH=$(ARCH) DESKTOP=aero OPTIMIZE=$(OPTIMIZE)

# ── Run Targets ──

run: run-uefi

run-uefi: esp
	@echo "[AERO] Starting QEMU (UEFI + ZBM + Aero, $(RESOLUTION))..."
	@mkdir -p $(TMP_DIR)
	@cp -f $(OVMF_VARS) $(TMP_DIR)/OVMF_VARS.fd
	qemu-system-x86_64 \
		-drive if=pflash,format=raw,readonly=on,file=$(OVMF_CODE) \
		-drive if=pflash,format=raw,file=$(TMP_DIR)/OVMF_VARS.fd \
		-drive format=raw,file=$(ESP_IMG) \
		-m $(QEMU_MEM) \
		-serial stdio \
		-display gtk,zoom-to-fit=on,show-cursor=on \
		-vga std \
		-no-reboot \
		-no-shutdown \
		-usb \
		-device usb-mouse \
		-device usb-kbd

run-bios:
	@echo "[AERO] BIOS/MBR + ZBM (root Makefile)..."
	cd $(ROOT_DIR) && $(MAKE) run ARCH=$(ARCH) DESKTOP=aero BOOT_METHOD=mbr BOOTLOADER=zbm OPTIMIZE=$(OPTIMIZE)

# ── Resources / Fonts ──

resources:
	@echo "[AERO] Resources manifest:"
	@echo "  Wallpapers: $(shell ls $(AERO_DIR)/resources/wallpapers/*.svg 2>/dev/null | wc -l) SVG files"
	@echo "  Icons:      $(shell ls $(AERO_DIR)/resources/icons/*.svg 2>/dev/null | wc -l) SVG files"
	@echo "  Cursors:    $(shell ls $(AERO_DIR)/resources/cursors/*.svg 2>/dev/null | wc -l) SVG files"
	@echo "  Themes:     $(shell ls $(AERO_DIR)/resources/themes/*.theme 2>/dev/null | wc -l) theme files"
	@echo "  Sounds:     $(shell ls -d $(AERO_DIR)/resources/sounds/*/ 2>/dev/null | wc -l) sound schemes"

fonts:
	@echo "[AERO] Fetching fonts from ZirconOSFonts..."
	@if [ -x $(FONTS_DIR)/fetch-fonts.sh ]; then \
		cd $(FONTS_DIR) && ./fetch-fonts.sh; \
	else \
		echo "[AERO] Warning: $(FONTS_DIR)/fetch-fonts.sh not found"; \
	fi
	@echo "[AERO] Fonts ready"

# ── Clean ──

clean:
	@echo "[AERO] Cleaning build artifacts..."
	rm -rf $(AERO_DIR)/.zig-cache $(AERO_DIR)/zig-out
	rm -rf $(BUILD_DIR)
	@echo "[AERO] Clean done"

