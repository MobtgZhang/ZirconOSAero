# ZirconOSAero — NT 6.1 (Windows 7) style hybrid microkernel OS (Zig)
# 所有配置已合并到此文件，不需要单独 build.conf
# 覆盖方式: make DESKTOP=aero BOOT_METHOD=uefi
#
# Requires: zig, qemu-system-* (per ARCH), OVMF/EDK2 firmware, xorriso, mtools, dosfstools

.PHONY: all build build-release run run-debug iso iso-debug iso-release \
	build-zbm build-esp build-desktop fetch-assets fetch-firmware \
	test clean help show-config sync-resolution

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  CONFIGURATION (原 build.conf 已合并到此)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

VERSION      := 6.1.0
ARCH         ?= x86_64
BOOT_METHOD  ?= uefi
LOONGARCH64_QEMU_MODE ?= uefi
LOONGARCH64_VIRT_GRAPHICS ?= on
BOOTLOADER   ?= zbm
DESKTOP      ?= aero
OPTIMIZE     ?= Debug

# 分辨率配置
RESOLUTION   ?= 1440x900x32
ZBM_RES_W    := $(word 1,$(subst x, ,$(RESOLUTION)))
ZBM_RES_H    := $(word 2,$(subst x, ,$(RESOLUTION)))

# QEMU 内存配置
QEMU_MEM     ?= 8G

# 功能开关
ENABLE_IDT   ?= true
DEBUG_LOG    ?= true
MOUSE_DEBUG  ?= false
DESKTOP_BISECT ?= false
AERO_BLUR_LIGHT ?= false
QEMU_GTK_ZOOM ?= zoom-to-fit=off
AGENT_NDJSON ?= false

# GPU 支持
AMD_IGPU   ?= true
AMD_IGPU_DEFER_PROBE ?= false
AMD_KMS_EXPERIMENTAL ?= false
INTEL_IGPU   ?= true
INTEL_IGPU_DEFER_PROBE ?= false
INTEL_KMS_EXPERIMENTAL ?= false
NVIDIA_GPU ?= true
NVIDIA_GPU_DEFER_PROBE ?= false
NVIDIA_KMS_EXPERIMENTAL ?= false
NVIDIA_HDMI_SYNC ?= false
DESKTOP_IDLE_SPIN ?= true

# LoongArch 配置
ifeq ($(ARCH),loongarch64)
LOONGSON_IGPU ?= true
else
LOONGSON_IGPU ?= false
endif
LOONGSON_IGPU_DEFER_PROBE ?= false
LOONGSON_KMS_EXPERIMENTAL ?= false
LOONGARCH64_QEMU_MODE ?= uefi
LOONGARCH64_VIRT_GRAPHICS ?= on
QEMU_LOONGARCH64_GTK_OPTS ?= $(QEMU_GTK_ZOOM),show-tabs=on
QEMU_LOONGARCH64_DISPLAY ?= gtk,$(QEMU_LOONGARCH64_GTK_OPTS)
QEMU_LOONGARCH64_CPU ?= max
QEMU_LOONGARCH64_SMP ?= 1
LOONGARCH64_QEMU_VIRTIO_GPU ?= 0

# MIPS64EL 配置
QEMU_MIPS64EL_CPU ?= Loongson-3A4000

# AArch64/RISC-V 配置
AARCH64_PFLASH_MB ?= 64
RISCV64_QEMU_VIRTIO_GPU ?= 0
AARCH64_QEMU_VIRTIO_GPU ?= 0
QEMU_DISPLAY_BACKEND ?= gtk
QEMU_GTK_EXTRA ?= ,grab-on-hover=on

# 配置验证
VALID_DESKTOPS := aero none
ifeq ($(filter $(DESKTOP),$(VALID_DESKTOPS)),)
$(error Invalid DESKTOP='$(DESKTOP)'. Valid: $(VALID_DESKTOPS))
endif

VALID_BOOT_METHODS := mbr uefi
ifeq ($(filter $(BOOT_METHOD),$(VALID_BOOT_METHODS)),)
$(error Invalid BOOT_METHOD='$(BOOT_METHOD)'. Valid: $(VALID_BOOT_METHODS))
endif

VALID_BOOTLOADERS := zbm
ifeq ($(filter $(BOOTLOADER),$(VALID_BOOTLOADERS)),)
$(error Invalid BOOTLOADER='$(BOOTLOADER)'. This project uses ZBM only: zbm)
endif

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  PATH CONFIGURATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ROOT_DIR     := $(shell pwd)
LOG_TXT      := $(ROOT_DIR)/.log/log.txt
BUILD_DIR    := $(ROOT_DIR)/build
TMP_DIR      := $(BUILD_DIR)/tmp
RELEASE_DIR  := $(BUILD_DIR)/release
TEST_RESULTS_DIR := $(BUILD_DIR)/test-results
FIRMWARE_DIR ?= $(ROOT_DIR)/firmware
ZBM_DIR      := $(TMP_DIR)/zbm
ZBM_SRC_DIR  := $(ROOT_DIR)/boot/zbm/bios
UEFI_PREFIX  := $(TMP_DIR)/uefi-prefix
UEFI_CACHE   := $(TMP_DIR)/uefi-cache
FONTS_DIR    := $(ROOT_DIR)/src/fonts
THEME_DIR    := $(ROOT_DIR)/src/desktop/$(DESKTOP)

# 内核与固件路径
KERNEL_ELF_DEBUG := $(TMP_DIR)/kernel-prefix/bin/kernel
KERNEL_ELF       := $(TMP_DIR)/kernel.elf
ISO_DEBUG        := $(RELEASE_DIR)/zirconos-$(VERSION)-uefi-$(ARCH)-debug.iso
ISO_RELEASE      := $(RELEASE_DIR)/zirconos-$(VERSION)-uefi-$(ARCH)-release.iso
ESP_IMG          := $(BUILD_DIR)/esp-$(ARCH).img
ESP_IMG_AARCH64  := $(BUILD_DIR)/esp-aarch64.img
ESP_IMG_RISCV64  := $(BUILD_DIR)/esp-riscv64.img
ESP_IMG_LOONGARCH64 := $(BUILD_DIR)/esp-loongarch64.img
ESP_IMG_MB       ?= 256
ZBM_DISK_MBR     := $(BUILD_DIR)/zirconos-mbr.img
ZBM_DISK_GPT     := $(BUILD_DIR)/zirconos-gpt.img

# ZBM 构建产物
ZBM_LOONGARCH64_O   := $(ROOT_DIR)/zig-out/zbm_loongarch64.o
ZBM_LOONGARCH64_EFI := $(BUILD_DIR)/BOOTLOONGARCH64.EFI
ZBM_RISCV64_O       := $(ROOT_DIR)/zig-out/zbm_riscv64.o
ZBM_RISCV64_EFI     := $(BUILD_DIR)/BOOTRISCV64.EFI

# 固件路径
OVMF_CODE    ?= $(if $(wildcard $(FIRMWARE_DIR)/OVMF_CODE-x86_64.fd),$(FIRMWARE_DIR)/OVMF_CODE-x86_64.fd,/usr/share/OVMF/OVMF_CODE_4M.fd)
OVMF_VARS    ?= $(if $(wildcard $(FIRMWARE_DIR)/OVMF_VARS-x86_64.fd),$(FIRMWARE_DIR)/OVMF_VARS-x86_64.fd,/usr/share/OVMF/OVMF_VARS_4M.fd)
AARCH64_EFI_CODE ?= $(FIRMWARE_DIR)/QEMU_EFI-aarch64.fd
AARCH64_EFI_VARS ?= $(FIRMWARE_DIR)/QEMU_VARS-aarch64.fd
RISCV64_EFI_CODE ?= $(FIRMWARE_DIR)/VIRT-riscv64.fd
LOONGARCH64_FIRMWARE_DIR ?= $(HOME)/Firmware/LoongArchVirtMachine
LOONGARCH64_EFI_CODE ?= $(if $(wildcard $(LOONGARCH64_FIRMWARE_DIR)/QEMU_EFI.fd),$(LOONGARCH64_FIRMWARE_DIR)/QEMU_EFI.fd,$(FIRMWARE_DIR)/QEMU_EFI-loongarch64.fd)
LOONGARCH64_EFI_VARS ?= $(if $(wildcard $(LOONGARCH64_FIRMWARE_DIR)/QEMU_EFI.fd),$(LOONGARCH64_FIRMWARE_DIR)/QEMU_VARS.fd,$(FIRMWARE_DIR)/QEMU_VARS-loongarch64.fd)
LOONGARCH64_BOOT_EFI ?= $(firstword $(wildcard $(LOONGARCH64_FIRMWARE_DIR)/BOOTLOONGARCH64.EFI $(FIRMWARE_DIR)/BOOTLOONGARCH64.EFI))

# UEFI 路径
ifeq ($(ARCH),x86_64)
UEFI_EFI         := $(UEFI_PREFIX)/bin/BOOTX64.efi
else ifeq ($(ARCH),aarch64)
UEFI_EFI         := $(UEFI_PREFIX)/bin/BOOTAA64.efi
else ifeq ($(ARCH),riscv64)
UEFI_EFI         := $(ZBM_RISCV64_EFI)
else
UEFI_EFI         := $(UEFI_PREFIX)/bin/BOOTX64.efi
endif

# 通用命令
SYNC_RESOLUTION_CMD = ZIRCON_RESOLUTION="$(RESOLUTION)" python3 $(ROOT_DIR)/scripts/devtools/sync_resolution_config.py

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  QEMU CONFIGURATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ifeq ($(QEMU_DISPLAY_BACKEND),sdl)
QEMU_X86_VIDEO_FLAGS := -display sdl -vga std
else
QEMU_X86_VIDEO_FLAGS := -display gtk,$(QEMU_GTK_ZOOM),show-cursor=on$(QEMU_GTK_EXTRA) -vga std
endif

QEMU_COMMON_X86 := -machine pc -m $(QEMU_MEM) -serial stdio -no-reboot -no-shutdown \
	$(QEMU_X86_VIDEO_FLAGS) \
	-device virtio-mouse-pci -device virtio-keyboard-pci -device virtio-tablet-pci

QEMU_X86_UEFI_MACHINE ?= q35
ifeq ($(shell test -r /dev/kvm && echo yes),yes)
QEMU_X86_UEFI_ACCEL ?= kvm
QEMU_X86_UEFI_CPU ?= -cpu host
else
QEMU_X86_UEFI_ACCEL ?= tcg
QEMU_X86_UEFI_CPU ?= -cpu max
endif
QEMU_SMP_UEFI ?= 2
QEMU_X86_UEFI_NET ?= 1
ifeq ($(QEMU_X86_UEFI_NET),1)
QEMU_X86_UEFI_NETDEV := -netdev user,id=net0 -device virtio-net-pci,netdev=net0
else
QEMU_X86_UEFI_NETDEV :=
endif
QEMU_COMMON_X86_UEFI := -machine $(QEMU_X86_UEFI_MACHINE),accel=$(QEMU_X86_UEFI_ACCEL) \
	$(QEMU_X86_UEFI_CPU) -smp $(QEMU_SMP_UEFI) -m $(QEMU_MEM) \
	-serial stdio -no-reboot -no-shutdown \
	$(QEMU_X86_VIDEO_FLAGS) \
	-device virtio-mouse-pci -device virtio-keyboard-pci -device virtio-tablet-pci \
	$(QEMU_X86_UEFI_NETDEV)

QEMU_COMMON_AARCH64 := -M virt,highmem-ecam=off -cpu cortex-a72 -m $(QEMU_MEM) -serial stdio \
	-no-reboot -no-shutdown -display gtk,$(QEMU_GTK_ZOOM)$(QEMU_GTK_EXTRA)

QEMU_COMMON_RISCV64 := -M virt -cpu rv64 -m $(QEMU_MEM) \
	-serial file:/tmp/zircon-riscv64-serial.txt \
	-no-reboot -no-shutdown -display gtk,$(QEMU_GTK_ZOOM)$(QEMU_GTK_EXTRA)

# AArch64 设备配置
ifeq ($(AARCH64_QEMU_VIRTIO_GPU),1)
QEMU_AARCH64_FB_DEVICE := -device virtio-gpu-pci,id=zircon_vgpu \
	-device ramfb,id=zircon_ramfb
QEMU_AARCH64_VIRTIO_INPUT := -device virtio-tablet-pci,display=zircon_vgpu \
	-device virtio-keyboard-pci,display=zircon_vgpu
else
QEMU_AARCH64_FB_DEVICE := -device ramfb,id=zircon_ramfb
QEMU_AARCH64_VIRTIO_INPUT := -device virtio-mouse-pci -device virtio-keyboard-pci
endif
QEMU_AARCH64_DEVICES := \
	-drive if=none,id=zircon-esp-a64,file=$(ESP_IMG_AARCH64),format=raw \
	-device virtio-blk-pci,drive=zircon-esp-a64,bootindex=0 \
	$(QEMU_AARCH64_FB_DEVICE) \
	$(QEMU_AARCH64_VIRTIO_INPUT) \
	-device qemu-xhci,id=xhci_a64 \
	-device usb-kbd,bus=xhci_a64.0

# RISC-V64 设备配置
ifeq ($(RISCV64_QEMU_VIRTIO_GPU),1)
QEMU_RISCV64_FB_DEVICE := -device virtio-gpu-pci,id=zircon_vgpu \
	-device ramfb,id=zircon_ramfb
QEMU_RISCV64_VIRTIO_INPUT := -device virtio-tablet-pci,display=zircon_vgpu \
	-device virtio-keyboard-pci,display=zircon_vgpu
else
QEMU_RISCV64_FB_DEVICE := -device ramfb,id=zircon_ramfb
QEMU_RISCV64_VIRTIO_INPUT := -device virtio-mouse-pci -device virtio-keyboard-pci
endif
QEMU_RISCV64_EXTRA := \
	$(QEMU_RISCV64_FB_DEVICE) \
	$(QEMU_RISCV64_VIRTIO_INPUT) \
	-device qemu-xhci,id=xhci_rv \
	-device usb-kbd,bus=xhci_rv.0

# LoongArch64 设备配置
QEMU_LOONGARCH64_BASE := -M virt,graphics=$(LOONGARCH64_VIRT_GRAPHICS) -cpu $(QEMU_LOONGARCH64_CPU) \
	-smp $(QEMU_LOONGARCH64_SMP) -m $(QEMU_MEM) -serial stdio \
	-no-reboot -no-shutdown -display $(QEMU_LOONGARCH64_DISPLAY)

ifeq ($(LOONGARCH64_QEMU_VIRTIO_GPU),0)
QEMU_LOONGARCH64_FB_DEVICE := -device ramfb,id=zircon_ramfb
QEMU_LOONGARCH64_VIRTIO_INPUT := -device virtio-mouse-pci -device virtio-keyboard-pci
else ifeq ($(LOONGARCH64_QEMU_VIRTIO_GPU),2)
QEMU_LOONGARCH64_FB_DEVICE := -device virtio-gpu-pci,id=zircon_vgpu
QEMU_LOONGARCH64_VIRTIO_INPUT := -device virtio-tablet-pci,display=zircon_vgpu -device virtio-keyboard-pci,display=zircon_vgpu
else
QEMU_LOONGARCH64_FB_DEVICE := -device ramfb,id=zircon_ramfb -device virtio-gpu-pci,id=zircon_vgpu
QEMU_LOONGARCH64_VIRTIO_INPUT := -device virtio-mouse-pci -device virtio-keyboard-pci
endif

QEMU_LOONGARCH64_DEVICES := \
	-drive if=none,id=zircon-esp0,file=$(ESP_IMG_LOONGARCH64),format=raw \
	-device virtio-blk-pci,drive=zircon-esp0,bootindex=0 \
	$(QEMU_LOONGARCH64_FB_DEVICE) \
	$(QEMU_LOONGARCH64_VIRTIO_INPUT) \
	-device qemu-xhci,id=xhci \
	-device usb-kbd,bus=xhci.0

# 向后兼容
QEMU_COMMON := $(QEMU_COMMON_X86)

# 创建日志目录
$(dir $(LOG_TXT)):
	@mkdir -p $@

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  DEFAULT TARGET
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ifeq ($(ZIRCON_NO_LOG),1)
all: run
else
all: $(dir $(LOG_TXT))
	+@$(MAKE) ZIRCON_NO_LOG=1 all 2>&1 | tee $(LOG_TXT)
endif

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  UTILITY TARGETS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

show-config:
	@echo "╔══════════════════════════════════════════════╗"
	@echo "║   ZirconOSAero (NT 6.1 style) v$(VERSION) config   ║"
	@echo "╠══════════════════════════════════════════════╣"
	@echo "║  ARCH         = $(ARCH)"
	@echo "║  BOOT_METHOD  = $(BOOT_METHOD)"
	@echo "║  BOOTLOADER   = $(BOOTLOADER)"
	@echo "║  DESKTOP      = $(DESKTOP)"
	@echo "║  OPTIMIZE     = $(OPTIMIZE)"
	@echo "║  RESOLUTION   = $(RESOLUTION)"
	@echo "║  ZBM/resolution = $(ZBM_RES_W)x$(ZBM_RES_H)"
	@echo "║  QEMU_MEM     = $(QEMU_MEM)"
	@echo "║  ENABLE_IDT   = $(ENABLE_IDT)"
	@echo "║  DEBUG_LOG    = $(DEBUG_LOG)"
	@echo "╚══════════════════════════════════════════════╝"

sync-resolution:
	@mkdir -p $(TMP_DIR)
	@$(SYNC_RESOLUTION_CMD)

fetch-assets:
	@bash $(ROOT_DIR)/scripts/fetch/fetch-assets.sh

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  BUILD TARGETS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$(BUILD_DIR) $(TMP_DIR) $(RELEASE_DIR) $(TEST_RESULTS_DIR):
	@mkdir -p $@

build: $(TMP_DIR) sync-resolution
	@zig build kernel -Darch=$(ARCH) -Ddesktop=$(DESKTOP) -Doptimize=$(OPTIMIZE) \
		-Denable_idt=$(ENABLE_IDT) -Ddebug=$(DEBUG_LOG) -Dmouse_debug=$(MOUSE_DEBUG) \
		-Damd_igpu=$(AMD_IGPU) -Dintel_igpu=$(INTEL_IGPU) \
		-Dnvidia_gpu=$(NVIDIA_GPU) -Dloongson_igpu=$(LOONGSON_IGPU) \
		--prefix $(TMP_DIR)/kernel-prefix
	@cp $(KERNEL_ELF_DEBUG) $(KERNEL_ELF)

build-release: $(TMP_DIR) sync-resolution
	@zig build kernel -Darch=$(ARCH) -Ddesktop=$(DESKTOP) -Doptimize=ReleaseSafe \
		-Denable_idt=$(ENABLE_IDT) -Ddebug=false -Dmouse_debug=$(MOUSE_DEBUG) \
		-Damd_igpu=$(AMD_IGPU) -Dintel_igpu=$(INTEL_IGPU) \
		-Dnvidia_gpu=$(NVIDIA_GPU) -Dloongson_igpu=$(LOONGSON_IGPU) \
		--prefix $(TMP_DIR)/kernel-prefix
	@cp $(KERNEL_ELF_DEBUG) $(KERNEL_ELF)

# 运行测试套件
test: $(TMP_DIR) $(TEST_RESULTS_DIR)
	@zig build test -Darch=$(ARCH) -Ddesktop=$(DESKTOP) -Doptimize=Debug \
		-Denable_idt=$(ENABLE_IDT) -Ddebug=$(DEBUG_LOG) \
		2>&1 | tee $(TEST_RESULTS_DIR)/test-results.txt
	@echo "✅ 所有测试执行完成，结果已保存到 build/test-results/test-results.txt"

# 单独运行Aero桌面模块测试
test-aero: $(TMP_DIR) $(TEST_RESULTS_DIR)
	@cd src/desktop/aero && zig build test \
		2>&1 | tee $(TEST_RESULTS_DIR)/aero-test-results.txt
	@echo "✅ Aero桌面模块测试执行完成，结果已保存到 build/test-results/aero-test-results.txt"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  ESP / UEFI BOOT TARGETS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 构建 UEFI ESP 镜像（支持 x86_64、aarch64 和 riscv64）
build-esp: build $(BUILD_DIR)
ifeq ($(ARCH),x86_64)
ifeq ($(BOOT_METHOD),uefi)
	@echo "[ZirconOS] 构建 x86_64 UEFI ESP 镜像..."
	@# 先构建 UEFI ZBM (BOOTX64.EFI)
	@zig build uefi -Darch=x86_64 -Doptimize=ReleaseSafe
	@# UEFI EFI 位于 zig-out/bin/BOOTX64.efi
	@if [ ! -f "$(ROOT_DIR)/zig-out/bin/BOOTX64.efi" ]; then \
		echo "[ZirconOS] ERROR: 找不到 BOOTX64.EFI"; \
		exit 1; \
	fi
	@echo "[ZirconOS] 使用 UEFI EFI: $(ROOT_DIR)/zig-out/bin/BOOTX64.efi"
	@bash $(ROOT_DIR)/scripts/build/mkesp-x86_64.sh \
		$(ESP_IMG) \
		$(KERNEL_ELF) \
		$(ROOT_DIR)/zig-out/bin/BOOTX64.efi
endif
endif
ifeq ($(ARCH),aarch64)
ifeq ($(BOOT_METHOD),uefi)
	@echo "[ZirconOS] 构建 aarch64 UEFI ESP 镜像..."
	@# 先构建 UEFI ZBM (BOOTAA64.EFI)
	@zig build uefi -Darch=aarch64 -Doptimize=ReleaseSafe
	@# UEFI EFI 位于 zig-out/bin/BOOTAA64.efi
	@if [ ! -f "$(ROOT_DIR)/zig-out/bin/BOOTAA64.efi" ]; then \
		echo "[ZirconOS] ERROR: 找不到 BOOTAA64.EFI"; \
		exit 1; \
	fi
	@echo "[ZirconOS] 使用 UEFI EFI: $(ROOT_DIR)/zig-out/bin/BOOTAA64.efi"
	@bash $(ROOT_DIR)/scripts/build/mkesp-aarch64.sh \
		$(ESP_IMG) \
		$(KERNEL_ELF) \
		$(ROOT_DIR)/zig-out/bin/BOOTAA64.efi
endif
endif
ifeq ($(ARCH),riscv64)
	@echo "[ZirconOS] 构建 riscv64 ESP 镜像..."
	@# RISC-V ZBM 需要先构建 Zig 对象，然后链接 GNU-EFI
	@zig build zbm-riscv64-uefi -Darch=riscv64 -Doptimize=ReleaseSafe \
		-Ddesktop=$(DESKTOP) -Ddebug=$(DEBUG_LOG) \
		-Dzbm_preferred_fb_width=$(ZBM_RES_W) \
		-Dzbm_preferred_fb_height=$(ZBM_RES_H)
	@# 构建 EFI 文件
	@bash $(ROOT_DIR)/scripts/build/zbm-riscv64-efi.sh \
		$(ZBM_RISCV64_O) \
		$(BUILD_DIR)/BOOTRISCV64.EFI
	@if [ ! -f "$(BUILD_DIR)/BOOTRISCV64.EFI" ]; then \
		echo "[ZirconOS] ERROR: 找不到 BOOTRISCV64.EFI"; \
		exit 1; \
	fi
	@echo "[ZirconOS] 使用 UEFI EFI: $(BUILD_DIR)/BOOTRISCV64.EFI"
	@bash $(ROOT_DIR)/scripts/build/mkesp-riscv64.sh \
		$(ESP_IMG) \
		$(KERNEL_ELF) \
		$(BUILD_DIR)/BOOTRISCV64.EFI
endif
ifeq ($(ARCH),loongarch64)
	@echo "[ZirconOS] 构建 loongarch64 ESP 镜像..."
	@# LoongArch ZBM 需要先构建 Zig 对象，然后链接 GNU-EFI
	@zig build zbm-loongarch-uefi -Darch=loongarch64 -Doptimize=ReleaseSafe \
		-Ddesktop=$(DESKTOP) -Ddebug=$(DEBUG_LOG) \
		-Dzbm_preferred_fb_width=$(ZBM_RES_W) \
		-Dzbm_preferred_fb_height=$(ZBM_RES_H)
	@# 构建 EFI 文件 → BOOTLOONGARCH64.EFI
	@bash $(ROOT_DIR)/scripts/build/zbm-loongarch64-efi.sh \
		$(ZBM_LOONGARCH64_O) \
		$(BUILD_DIR)/BOOTLOONGARCH64.EFI
	@if [ ! -f "$(BUILD_DIR)/BOOTLOONGARCH64.EFI" ]; then \
		echo "[ZirconOS] ERROR: 找不到 BOOTLOONGARCH64.EFI"; \
		exit 1; \
	fi
	@echo "[ZirconOS] 使用 UEFI EFI: $(BUILD_DIR)/BOOTLOONGARCH64.EFI"
	@BOOTLOADER=zbm ZBM_LOONGARCH64_EFI="$(BUILD_DIR)/BOOTLOONGARCH64.EFI" \
		bash $(ROOT_DIR)/scripts/build/mkesp-loongarch64.sh \
		$(ESP_IMG) \
		$(KERNEL_ELF)
endif

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  RUN TARGETS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

run: build build-esp
	@$(MAKE) show-config
	@echo "Starting QEMU..."
	@if [ "$(ARCH)" = "x86_64" ] && [ "$(BOOT_METHOD)" = "uefi" ]; then \
		qemu-system-x86_64 $(QEMU_COMMON_X86_UEFI) \
			-drive if=pflash,format=raw,readonly=on,file=$(OVMF_CODE) \
			-drive if=pflash,format=raw,file=$(OVMF_VARS) \
			-drive file=$(ESP_IMG),format=raw,if=virtio; \
	elif [ "$(ARCH)" = "x86_64" ] && [ "$(BOOT_METHOD)" = "mbr" ]; then \
		qemu-system-x86_64 $(QEMU_COMMON_X86) -kernel $(KERNEL_ELF); \
	elif [ "$(ARCH)" = "aarch64" ]; then \
		echo "[ZirconOS] aarch64: 准备 pflash (64MB)..."; \
		rm -f $(BUILD_DIR)/pflash-code-aarch64.img $(BUILD_DIR)/pflash-vars-aarch64.img; \
		dd if=/dev/zero of=$(BUILD_DIR)/pflash-code-aarch64.img bs=1M count=64 status=none; \
		dd if=$(AARCH64_EFI_CODE) of=$(BUILD_DIR)/pflash-code-aarch64.img bs=1 conv=notrunc status=none; \
		dd if=/dev/zero of=$(BUILD_DIR)/pflash-vars-aarch64.img bs=1M count=64 status=none; \
		dd if=$(AARCH64_EFI_VARS) of=$(BUILD_DIR)/pflash-vars-aarch64.img bs=1 conv=notrunc status=none; \
		qemu-system-aarch64 $(QEMU_COMMON_AARCH64) \
			-drive if=pflash,format=raw,readonly=on,file=$(BUILD_DIR)/pflash-code-aarch64.img \
			-drive if=pflash,format=raw,file=$(BUILD_DIR)/pflash-vars-aarch64.img \
			$(QEMU_AARCH64_DEVICES); \
	elif [ "$(ARCH)" = "riscv64" ]; then \
		qemu-system-riscv64 $(QEMU_COMMON_RISCV64) \
			-bios $(RISCV64_EFI_CODE) \
			$(QEMU_RISCV64_EXTRA) \
			-drive file=$(ESP_IMG_RISCV64),if=virtio,format=raw; \
	elif [ "$(ARCH)" = "loongarch64" ]; then \
		if [ "$(LOONGARCH64_QEMU_MODE)" = "kernel" ]; then \
			qemu-system-loongarch64 $(QEMU_LOONGARCH64_BASE) $(QEMU_LOONGARCH64_DEVICES) \
				-kernel $(KERNEL_ELF); \
		else \
			# 使用 pflash 方式加载 EFI 固件，确保从 ESP 盘启动 \
			qemu-system-loongarch64 $(QEMU_LOONGARCH64_BASE) \
				-drive if=pflash,format=raw,readonly=on,file=$(LOONGARCH64_EFI_CODE) \
				-drive if=pflash,format=raw,file=$(LOONGARCH64_EFI_VARS) \
				$(QEMU_LOONGARCH64_DEVICES); \
		fi; \
	elif [ "$(ARCH)" = "mips64el" ]; then \
		qemu-system-mips64el -M malta -cpu $(QEMU_MIPS64EL_CPU) -m $(QEMU_MEM) \
			-serial stdio -no-reboot -no-shutdown \
			-display gtk,$(QEMU_GTK_ZOOM)$(QEMU_GTK_EXTRA) \
			-kernel $(KERNEL_ELF); \
	else \
		echo "Unsupported ARCH: $(ARCH)"; \
		exit 1; \
	fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  CLEANUP
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

clean:
	@zig build clean
	@rm -rf $(BUILD_DIR)
	@echo "Clean complete."
