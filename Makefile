# ZirconOSAero — NT 6.1 (Windows 7) style hybrid microkernel OS (Zig)
# Build system reads build.conf. Override: make DESKTOP=aero BOOT_METHOD=uefi
#
# Requires: zig, qemu-system-* (per ARCH), OVMF/EDK2 firmware, xorriso, mtools, dosfstools

.PHONY: all build build-release iso run run-debug \
	build-zbm-uefi build-zbm-loongarch-uefi build-zbm-riscv64-uefi build-zbm-loongarch64-stub build-zbm-bios build-zbm-disk build-esp \
	build-desktop build-desktop-all build-desktop-dll \
	fetch-themes fetch-firmware fetch-gnu-efi fetch-gnu-efi-riscv64 fetch-loongarch-boot-efi fonts resources \
	run-aarch64 run-riscv64 run-loongarch64 run-loongarch64-autozbm run-aarch64-debug run-riscv64-debug run-loongarch64-debug \
	test test-kernel test-config test-boot test-all smoke-qemu-mbr \
	clean help show-config configure

# ══════════════════════════════════════════════════════
#  Configuration: read from build.conf, allow overrides
# ══════════════════════════════════════════════════════

-include build.conf

VERSION      := 6.1.0
ARCH         ?= x86_64
BOOT_METHOD  ?= uefi
BOOTLOADER   ?= zbm
DESKTOP      ?= aero
OPTIMIZE     ?= Debug
RESOLUTION   ?= 1024x768x32
QEMU_MEM     ?= 512M
# qemu-system-loongarch64 -M virt + EDK2: guest RAM must be strictly > 1G (else: ram_size must be greater than 1G).
QEMU_MEM_LOONGARCH64 ?= 1536M
ENABLE_IDT   ?= true
DEBUG_LOG    ?= true
# 鼠标诊断：串口/控制台 [MOUSEDBG] + 底栏显示 ptr x,y（不依赖 DEBUG_LOG）
MOUSE_DEBUG  ?= false
# Cursor 调试会话：内核经串口输出 AGENT_LOG:{...}，make run 2>&1 | bash scripts/agent-ingest-serial.sh
AGENT_NDJSON ?= false
# x86_64：枚举 AMD 1002 显示类 PCI、映射 MMIO；无硬件时静默回退 GOP。真机 Intel 可另开 INTEL_IGPU
AMD_IGPU   ?= true
# AMD PCI/BAR 探测延到首次 resolveDesktopFramebuffer（GOP 就绪后）
AMD_IGPU_DEFER_PROBE ?= false
# AMD 显示 MMIO 可选探测（默认关，仅 GOP handoff）
AMD_KMS_EXPERIMENTAL ?= false
# x86_64：Intel 8086 显示类（默认开；与 AMD 并存，帧缓冲解析链 Intel 先于 AMD）
INTEL_IGPU   ?= true
# Intel PCI/BAR 探测延到首次 resolveDesktopFramebuffer（GOP 就绪后）；对照固件/鼠标异常时可设 true
INTEL_IGPU_DEFER_PROBE ?= false
# Intel 显示 MMIO 可选探测（默认关，仅 GOP handoff）
INTEL_KMS_EXPERIMENTAL ?= false
# 桌面主循环不自旋 HLT（避免部分环境下 HLT 唤醒过稀导致 VirtIO/PS2 轮询「像卡住」）；QEMU CPU 占用略升
DESKTOP_IDLE_SPIN ?= true
# loongarch64：龙芯 0014 显示 PCI/MMIO（阶段一透传 GOP/ramfb）；其它 ARCH 下应为 false
ifeq ($(ARCH),loongarch64)
LOONGSON_IGPU ?= true
else
LOONGSON_IGPU ?= false
endif
LOONGSON_IGPU_DEFER_PROBE ?= false
LOONGSON_KMS_EXPERIMENTAL ?= false

# Validate DESKTOP
VALID_DESKTOPS := aero none
ifeq ($(filter $(DESKTOP),$(VALID_DESKTOPS)),)
$(error Invalid DESKTOP='$(DESKTOP)'. Valid: $(VALID_DESKTOPS))
endif

# Validate BOOT_METHOD
VALID_BOOT_METHODS := mbr uefi
ifeq ($(filter $(BOOT_METHOD),$(VALID_BOOT_METHODS)),)
$(error Invalid BOOT_METHOD='$(BOOT_METHOD)'. Valid: $(VALID_BOOT_METHODS))
endif

# Bootloader: ZBM only (no GRUB in this tree)
VALID_BOOTLOADERS := zbm
ifeq ($(filter $(BOOTLOADER),$(VALID_BOOTLOADERS)),)
$(error Invalid BOOTLOADER='$(BOOTLOADER)'. This project uses ZBM only: zbm)
endif

# LoongArch QEMU：勿与 x86 的 BOOT_METHOD 绑定。默认 UEFI+ESP+startup.nsh → ZBM 操作系统选择菜单；
# 仅内核调试时设 LOONGARCH64_QEMU_MODE=kernel（-kernel 直启，无 ZBM）。
ifeq ($(ARCH),loongarch64)
ifeq ($(origin LOONGARCH64_QEMU_MODE),undefined)
LOONGARCH64_QEMU_MODE := uefi
endif
endif

# ── Derived Paths ──

ROOT_DIR     := $(shell pwd)
BUILD_DIR    := $(ROOT_DIR)/build
TMP_DIR      := $(BUILD_DIR)/tmp
RELEASE_DIR  := $(BUILD_DIR)/release

KERNEL_ELF_DEBUG := $(TMP_DIR)/kernel-prefix/bin/kernel
KERNEL_ELF       := $(TMP_DIR)/kernel.elf
ISO              := $(RELEASE_DIR)/zirconos-$(VERSION)-$(ARCH).iso
TEST_RESULTS_DIR := $(BUILD_DIR)/test-results

# ── Firmware Paths (EDK2 nightly: https://retrage.github.io/edk2-nightly/) ──
FIRMWARE_DIR     ?= $(ROOT_DIR)/firmware

# x86_64: OVMF from EDK2 nightly (fallback to system OVMF)
OVMF_CODE    ?= $(if $(wildcard $(FIRMWARE_DIR)/OVMF_CODE-x86_64.fd),$(FIRMWARE_DIR)/OVMF_CODE-x86_64.fd,/usr/share/OVMF/OVMF_CODE_4M.fd)
OVMF_VARS    ?= $(if $(wildcard $(FIRMWARE_DIR)/OVMF_VARS-x86_64.fd),$(FIRMWARE_DIR)/OVMF_VARS-x86_64.fd,/usr/share/OVMF/OVMF_VARS_4M.fd)

# aarch64: QEMU_EFI from EDK2 nightly
AARCH64_EFI_CODE ?= $(FIRMWARE_DIR)/QEMU_EFI-aarch64.fd
AARCH64_EFI_VARS ?= $(FIRMWARE_DIR)/QEMU_VARS-aarch64.fd
# QEMU virt：pflash 槽位固定 64MiB；nightly 的 .fd 较小，run-aarch64 会在 $(TMP_DIR) 生成填充镜像
AARCH64_PFLASH_MB ?= 64

# riscv64: QEMU virt 固件（fetch-firmware → VIRT-riscv64.fd）
RISCV64_EFI_CODE ?= $(FIRMWARE_DIR)/VIRT-riscv64.fd

# loongarch64: prefer LoongArchVirtMachine bundle (QEMU_EFI.fd / QEMU_VARS.fd); else EDK2 nightly in $(FIRMWARE_DIR).
# Override: make LOONGARCH64_FIRMWARE_DIR=/path run
LOONGARCH64_FIRMWARE_DIR ?= $(HOME)/Firmware/LoongArchVirtMachine
LOONGARCH64_EFI_CODE ?= $(if $(wildcard $(LOONGARCH64_FIRMWARE_DIR)/QEMU_EFI.fd),$(LOONGARCH64_FIRMWARE_DIR)/QEMU_EFI.fd,$(FIRMWARE_DIR)/QEMU_EFI-loongarch64.fd)
LOONGARCH64_EFI_VARS ?= $(if $(wildcard $(LOONGARCH64_FIRMWARE_DIR)/QEMU_EFI.fd),$(LOONGARCH64_FIRMWARE_DIR)/QEMU_VARS.fd,$(FIRMWARE_DIR)/QEMU_VARS-loongarch64.fd)
# Optional: 备用 BOOTLOONGARCH64.EFI（如 EDK2 Shell），仅当未使用 ZBM 构建 ESP 时；正常流程为 ZBM。
LOONGARCH64_BOOT_EFI ?= $(firstword $(wildcard $(LOONGARCH64_FIRMWARE_DIR)/BOOTLOONGARCH64.EFI $(FIRMWARE_DIR)/BOOTLOONGARCH64.EFI))
# （LoongArch）LOONGARCH64_QEMU_MODE 默认已按 BOOT_METHOD 推导，见上；勿再在此处 ?= kernel。

ZBM_DIR          := $(TMP_DIR)/zbm
ZBM_SRC_DIR      := $(ROOT_DIR)/boot/zbm/bios
UEFI_PREFIX      := $(TMP_DIR)/uefi-prefix
UEFI_CACHE       := $(TMP_DIR)/uefi-cache
# Zig object + GNU-EFI → BOOT*.EFI（须先于 UEFI_EFI 赋值）
ZBM_LOONGARCH64_O   := $(TMP_DIR)/kernel-prefix/zbm_loongarch64.o
ZBM_LOONGARCH64_EFI := $(TMP_DIR)/zbm-loongarch64.efi
ZBM_RISCV64_O       := $(TMP_DIR)/kernel-prefix/zbm_riscv64.o
ZBM_RISCV64_EFI     := $(TMP_DIR)/zbm-riscv64.efi
ifeq ($(ARCH),x86_64)
UEFI_EFI         := $(UEFI_PREFIX)/bin/BOOTX64.efi
else ifeq ($(ARCH),aarch64)
UEFI_EFI         := $(UEFI_PREFIX)/bin/BOOTAA64.efi
else ifeq ($(ARCH),riscv64)
UEFI_EFI         := $(ZBM_RISCV64_EFI)
else
UEFI_EFI         := $(UEFI_PREFIX)/bin/BOOTX64.efi
endif
ESP_IMG          := $(BUILD_DIR)/esp-$(ARCH).img
# Fixed path for LoongArch QEMU (avoid := expansion when ARCH defaults to x86_64 but target is run-loongarch64).
ESP_IMG_LOONGARCH64 := $(BUILD_DIR)/esp-loongarch64.img
ZBM_DISK_MBR     := $(BUILD_DIR)/zirconos-mbr.img
ZBM_DISK_GPT     := $(BUILD_DIR)/zirconos-gpt.img

THEME_DIR_MAP_classic    := $(ROOT_DIR)/src/desktop/classic
THEME_DIR_MAP_luna       := $(ROOT_DIR)/src/desktop/luna
THEME_DIR_MAP_aero       := $(ROOT_DIR)/src/desktop/aero
THEME_DIR_MAP_modern     := $(ROOT_DIR)/src/desktop/modern
THEME_DIR_MAP_fluent     := $(ROOT_DIR)/src/desktop/fluent
THEME_DIR_MAP_sunvalley  := $(ROOT_DIR)/src/desktop/sunvalley
FONTS_DIR                := $(ROOT_DIR)/src/fonts

THEME_DIR := $(THEME_DIR_MAP_$(DESKTOP))

# Common QEMU flags
# PS/2 与 usb-mouse 在客户机内均为相对移动；未捕获输入时，宿主机光标与窗口内指针位置通常不一致。
# 在 QEMU 显示窗口内按 Ctrl+Alt+G 可切换鼠标捕获（Grab），捕获后相对移动更稳定。
# 若将来内核支持 USB HID 绝对指针，可改用 -device usb-tablet（需对应驱动）。
# 默认使用 i8042 PS/2 键鼠（IRQ1/IRQ12），与内核 PS/2 驱动一致。
# 勿默认附加 usb-mouse/usb-kbd：客户机内为 USB HID，当前内核无对应驱动，会导致“无鼠标/键盘”。
# Per-architecture QEMU flags
# 固定 i440fx+8259+板载 PS/2，避免 q35/IOAPIC-only 路径下 IRQ1/12 与 PIC 行为不一致导致键鼠失灵。
# 同时附加 virtio-input 键鼠（与 `virtio_input_pci.zig` 一致）：部分 QEMU/固件组合下 PS/2 流不可靠时有第二路径。
# 自定义 QEMU 时请勿删掉 -device virtio-mouse-pci（除非确认 PS/2 可用）；勿用 usb-tablet/usb-kbd 替代（内核无 USB HID）。
# grab-on-hover=on：指针移入窗口即抓取，REL 型 virtio-mouse 在未抓取时 QEMU 往往不发位移；设 QEMU_GTK_EXTRA= 可关闭。
# virtio-tablet-pci：GTK 未抓取时常走 ABS，驱动已把 ABS 差分转为位移（与 mouse 并存，MAX_INST≥3）。
QEMU_GTK_EXTRA ?= ,grab-on-hover=on
QEMU_COMMON_X86 := -machine pc -m $(QEMU_MEM) -serial stdio -no-reboot -no-shutdown \
	-display gtk,zoom-to-fit=on,show-cursor=on$(QEMU_GTK_EXTRA) -vga std \
	-device virtio-mouse-pci -device virtio-keyboard-pci -device virtio-tablet-pci

# highmem-ecam=off：PCIe ECAM 固定在 0x3f00_0000，与内核 pcie.zig 一致（否则默认 ECAM 可落在 >4GiB）
QEMU_COMMON_AARCH64 := -M virt,highmem-ecam=off -cpu cortex-a72 -m $(QEMU_MEM) -serial stdio \
	-no-reboot -no-shutdown -display gtk,zoom-to-fit=on

QEMU_COMMON_RISCV64 := -M virt -cpu rv64 -m $(QEMU_MEM) -serial stdio \
	-no-reboot -no-shutdown -display gtk,zoom-to-fit=on

# 与 LoongArch UEFI 路径类似：virtio-gpu + virtio-input（进内核后）；usb-kbd 供 UEFI/ZBM 菜单 ConIn
QEMU_AARCH64_DEVICES := \
	-drive if=none,id=zircon-esp-a64,file=$(BUILD_DIR)/esp-aarch64.img,format=raw \
	-device virtio-blk-pci,drive=zircon-esp-a64,bootindex=0 \
	-device virtio-gpu-pci,id=zircon_vgpu \
	-device virtio-tablet-pci,display=zircon_vgpu \
	-device virtio-keyboard-pci,display=zircon_vgpu \
	-device qemu-xhci,id=xhci_a64 \
	-device usb-kbd,bus=xhci_a64.0

# usb-kbd：与 AArch64 一致，部分 EDK2 下 virtio-keyboard 未挂 ConIn 时仍可用 USB 键盘操作 ZBM
# 显示：与 LoongArch 相同，virtio-gpu 与固件默认输出并存时 GTK 常提示 “Display output is not active”；默认 ramfb。
RISCV64_QEMU_VIRTIO_GPU ?= 0
ifeq ($(RISCV64_QEMU_VIRTIO_GPU),1)
QEMU_RISCV64_FB_DEVICE := -device virtio-gpu-pci,id=zircon_vgpu
QEMU_RISCV64_VIRTIO_INPUT := -device virtio-tablet-pci,display=zircon_vgpu -device virtio-keyboard-pci,display=zircon_vgpu
else
QEMU_RISCV64_FB_DEVICE := -device ramfb,id=zircon_ramfb
# 与 LoongArch ramfb 相同：mouse=REL（见上），勿绑 display 以免与 GTK 主控制台不一致。
QEMU_RISCV64_VIRTIO_INPUT := -device virtio-mouse-pci -device virtio-keyboard-pci
endif
QEMU_RISCV64_EXTRA := \
	$(QEMU_RISCV64_FB_DEVICE) \
	$(QEMU_RISCV64_VIRTIO_INPUT) \
	-device qemu-xhci,id=xhci_rv \
	-device usb-kbd,bus=xhci_rv.0

# LoongArch `virt` 公共参数（是否加 -bios / -kernel 由 LOONGARCH64_QEMU_MODE 决定）
# 默认 off：与 ramfb 桌面并存时，机内 GOP 易成 GTK 另一控制台。ramfb 路径用 virtio-mouse-pci（REL）：QEMU ui/input.c 里 tablet 仅 INPUT_EVENT_MASK_ABS，GTK 未抓取时常发 REL，tablet 永远匹配不到（H6 used 永 0）；不设 display= 则 con=NULL 走全局回退。需固件菜单高分辨率时可设 LOONGARCH64_VIRT_GRAPHICS=on。
LOONGARCH64_VIRT_GRAPHICS ?= off
QEMU_LOONGARCH64_BASE := -M virt,graphics=$(LOONGARCH64_VIRT_GRAPHICS) -cpu la464 -m $(QEMU_MEM_LOONGARCH64) -serial stdio \
	-no-reboot -no-shutdown -display gtk,zoom-to-fit=on
# virtio-blk bootindex：便于固件将磁盘列为启动候选（部分环境仍会因 BdsDxe Boot0001 失败而进 Shell）。
# USB 键盘：LoongArch virt 机无默认键鼠，UEFI ConIn 需 usb-kbd 才能接收按键；内核可能无 USB HID 驱动，但不影响 ZBM 菜单。
#
# 显示：virtio-gpu-pci 与 ramfb 同时存在时，QEMU gtk 常把主输出接到未扫描的 virtio-gpu。
# 默认 ramfb。ZBM（C/Zig）在 ExitBootServices 前将 GOP SetMode 到 ≥1024×768 并写入 handoff 时，内核用该 GOP（与 QEMU 主窗口同源）；
# 否则内核 `ramfb.setup()` 写 RAMFB_PHYS（部分配置下 GTK 仍扫固件 GOP 则看不见桌面，见 LOONGARCH64_VIRT_GRAPHICS）。virtio GPU：LOONGARCH64_QEMU_VIRTIO_GPU=1
LOONGARCH64_QEMU_VIRTIO_GPU ?= 0
ifeq ($(LOONGARCH64_QEMU_VIRTIO_GPU),1)
QEMU_LOONGARCH64_FB_DEVICE := -device virtio-gpu-pci,id=zircon_vgpu
# GTK 对未抓取指针多走 ABS → virtio-tablet；内核 parseLinuxInput 已支持 EV_ABS。
QEMU_LOONGARCH64_VIRTIO_INPUT := -device virtio-tablet-pci,display=zircon_vgpu -device virtio-keyboard-pci,display=zircon_vgpu
else
QEMU_LOONGARCH64_FB_DEVICE := -device ramfb,id=zircon_ramfb
# ramfb：virtio-mouse-pci + 不绑 display（见 LOONGARCH64_VIRT_GRAPHICS 注释）；多描述符 recv 见 virtio_input_pci.zig。
QEMU_LOONGARCH64_VIRTIO_INPUT := -device virtio-mouse-pci -device virtio-keyboard-pci
endif
QEMU_LOONGARCH64_DEVICES := \
	-drive if=none,id=zircon-esp0,file=$(ESP_IMG_LOONGARCH64),format=raw \
	-device virtio-blk-pci,drive=zircon-esp0,bootindex=0 \
	$(QEMU_LOONGARCH64_FB_DEVICE) \
	$(QEMU_LOONGARCH64_VIRTIO_INPUT) \
	-device qemu-xhci,id=xhci \
	-device usb-kbd,bus=xhci.0

# Backward compatibility
QEMU_COMMON := $(QEMU_COMMON_X86)

# ══════════════════════════════════════════════════════
#  Default target: build & run according to build.conf
# ══════════════════════════════════════════════════════

all: run

# ══════════════════════════════════════════════════════
#  show-config: display current build configuration
# ══════════════════════════════════════════════════════

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
	@echo "║  QEMU_MEM     = $(QEMU_MEM)"
	@if [ "$(ARCH)" = "loongarch64" ]; then echo "║  QEMU_MEM_LOONGARCH64 = $(QEMU_MEM_LOONGARCH64)  (run-loongarch64; QEMU virt requires >1G)"; fi
	@echo "║  ENABLE_IDT   = $(ENABLE_IDT)"
	@echo "║  DEBUG_LOG    = $(DEBUG_LOG)"
	@if [ "$(ARCH)" = "x86_64" ]; then \
		echo "║  AMD_IGPU   = $(AMD_IGPU)  (false=skip AMD PCI/MMIO probe)"; \
		echo "║  AMD_IGPU_DEFER_PROBE = $(AMD_IGPU_DEFER_PROBE)  (true=probe after GOP resolve)"; \
		echo "║  AMD_KMS_EXPERIMENTAL = $(AMD_KMS_EXPERIMENTAL)"; \
		echo "║  INTEL_IGPU   = $(INTEL_IGPU)  (true=probe Intel 8086 display PCI)"; \
		echo "║  INTEL_IGPU_DEFER_PROBE = $(INTEL_IGPU_DEFER_PROBE)  (true=probe after GOP resolve)"; \
		echo "║  INTEL_KMS_EXPERIMENTAL = $(INTEL_KMS_EXPERIMENTAL)"; \
		echo "║  DESKTOP_IDLE_SPIN = $(DESKTOP_IDLE_SPIN)  (true=no HLT in desktop loop)"; \
	fi
	@echo "║  FIRMWARE_DIR = $(FIRMWARE_DIR)"
	@if [ "$(ARCH)" = "loongarch64" ]; then \
		echo "║  LOONGARCH64_FIRMWARE_DIR = $(LOONGARCH64_FIRMWARE_DIR)"; \
		echo "║  LOONGARCH64_EFI_CODE     = $(LOONGARCH64_EFI_CODE)"; \
		echo "║  LOONGARCH64_BOOT_EFI     = $(LOONGARCH64_BOOT_EFI)"; \
		echo "║  LOONGARCH64_QEMU_MODE     = $(LOONGARCH64_QEMU_MODE)  (kernel|uefi; ZBM+UEFI only)"; \
		echo "║  LOONGARCH64_QEMU_VIRTIO_GPU = $(LOONGARCH64_QEMU_VIRTIO_GPU)  (0=ramfb 默认, 1=仅 virtio-gpu)"; \
		echo "║  LOONGARCH64_VIRT_GRAPHICS   = $(LOONGARCH64_VIRT_GRAPHICS)  (默认 off 利 ramfb+virtio-input; 要固件 GOP 可设 on)"; \
		echo "║  LOONGSON_IGPU = $(LOONGSON_IGPU)  (false=skip 0014 display PCI probe)"; \
		echo "║  LOONGSON_IGPU_DEFER_PROBE = $(LOONGSON_IGPU_DEFER_PROBE)"; \
		echo "║  LOONGSON_KMS_EXPERIMENTAL = $(LOONGSON_KMS_EXPERIMENTAL)"; \
	fi
	@if [ "$(ARCH)" = "riscv64" ]; then \
		echo "║  RISCV64_QEMU_VIRTIO_GPU = $(RISCV64_QEMU_VIRTIO_GPU)  (0=ramfb 默认, 1=virtio-gpu-pci)"; \
	fi
	@echo "╚══════════════════════════════════════════════╝"
	@if [ "$(ARCH)" = "aarch64" ]; then \
		if [ -d "$(FIRMWARE_DIR)" ]; then \
			echo "  EDK2 nightly firmware: $(FIRMWARE_DIR)"; \
		else \
			echo "  ⚠ EDK2 firmware not found. Run: make fetch-firmware"; \
		fi; \
	fi
	@if [ "$(ARCH)" = "loongarch64" ]; then \
		if [ -f "$(LOONGARCH64_EFI_CODE)" ]; then \
			echo "  LoongArch UEFI: $(LOONGARCH64_EFI_CODE) (OK)"; \
		else \
			echo "  ⚠ LoongArch UEFI missing: $(LOONGARCH64_EFI_CODE)"; \
			echo "     Set LOONGARCH64_FIRMWARE_DIR or run: make fetch-firmware"; \
		fi; \
	fi

# ══════════════════════════════════════════════════════
#  configure: interactive helper to edit build.conf
# ══════════════════════════════════════════════════════

configure:
	@python3 $(ROOT_DIR)/scripts/configure.py

# ══════════════════════════════════════════════════════
#  help
# ══════════════════════════════════════════════════════

help:
	@echo "ZirconOSAero v$(VERSION) — NT 6.1 (Windows 7) style, ZBM-only boot"
	@echo ""
	@echo "Configuration (edit build.conf or override via CLI):"
	@echo "  make show-config            Show current build.conf settings"
	@echo "  make configure              Interactive configuration wizard"
	@echo ""
	@echo "Build:"
	@echo "  make                        Build & run (using build.conf)"
	@echo "  make build                  Build kernel only"
	@echo "  make build-release          Build kernel (ReleaseSafe)"
	@echo "  make build-desktop          Build desktop theme (EXE + LIB + DLL)"
	@echo "  make build-desktop-all      Build all desktop themes"
	@echo "  make build-desktop-dll      Build desktop theme DLL only"
	@echo "  make iso                    Build UEFI bootable ISO (ZBM, xorriso; no GRUB)"
	@echo "  make build-zbm-uefi        Build ZBM UEFI application"
	@echo "  make build-zbm-bios        Build ZBM BIOS components"
	@echo "  make build-zbm-disk        Build ZBM bootable disk images"
	@echo "  make build-esp             Build EFI System Partition image"
	@echo ""
	@echo "Run (auto-selects from build.conf):"
	@echo "  make run                    Build + run per build.conf"
	@echo "  make run-debug              Run with GDB server on :1234"
	@echo "  make run-aarch64            UEFI boot on QEMU AArch64 (EDK2 nightly)"
	@echo "  make run-riscv64            UEFI boot on QEMU RISC-V64 virt (VIRT.fd + ESP; 默认 ramfb)"
	@echo "  make run-loongarch64        QEMU LoongArch64（默认: UEFI+ESP+startup.nsh → ZBM 菜单）"
	@echo "  make run-loongarch64-autozbm  同 run（LOONGARCH64_QEMU_MODE=uefi 别名）"
	@echo "  make run-aarch64-debug      AArch64 + GDB on :1234"
	@echo "  make run-riscv64-debug      RISC-V64 UEFI + GDB on :1234"
	@echo "  make run-loongarch64-debug  LoongArch64 + GDB on :1234"
	@echo ""
	@echo "Override examples:"
	@echo "  make DESKTOP=aero                        Aero desktop (default)"
	@echo "  make BOOT_METHOD=mbr BOOTLOADER=zbm      BIOS/MBR + ZBM (raw disk)"
	@echo "  make BOOT_METHOD=uefi BOOTLOADER=zbm     UEFI + ZBM (ESP)"
	@echo "  make DESKTOP=none                        Text/CMD mode"
	@echo "  make AMD_IGPU=false MOUSE_DEBUG=true     对照指针：排除 AMD 探测 + VirtIO 串口跟踪"
	@echo "  make INTEL_IGPU=false                    x86：关闭 Intel 8086 显示 PCI 探测（默认与 AMD 并存，解析链 Intel 先于 AMD）"
	@echo "  make DESKTOP_IDLE_SPIN=true              桌面循环不 HLT（调试 IRQ/鼠标）"
	@echo "  make run-riscv64 RISCV64_QEMU_VIRTIO_GPU=1  RISC-V QEMU 使用 virtio-gpu（易现 Display not active）"
	@echo ""
	@echo "Test:"
	@echo "  make test                   Run all tests"
	@echo "  make test-kernel            Kernel ELF verification tests"
	@echo "  make test-config            Build configuration tests"
	@echo "  make test-boot              Boot combination tests"
	@echo ""
	@echo "Firmware / toolchain:"
	@echo "  make fetch-firmware         Download EDK2 nightly UEFI firmware (→ ./download-edk2-nightly.sh)"
	@echo "  make fetch-gnu-efi          Build GNU-EFI (LoongArch ZBM 链接)"
	@echo "  make fetch-gnu-efi-riscv64  Build GNU-EFI ncroxon fork（RISC-V64 ZBM 链接，需 gcc-riscv64-linux-gnu）"
	@echo "  make fetch-loongarch-boot-efi  LoongArch: BOOTLOONGARCH64.EFI (EDK2 Shell, 可选备用)"
	@echo ""
	@echo "Resources:"
	@echo "  make fonts                  Fetch fonts"
	@echo "  make fetch-themes           Clone all theme repos"
	@echo "  make resources              List theme resources"
	@echo "  make clean                  Remove build artifacts"
	@echo ""
	@echo "Boot Paths (ZBM only):"
	@echo "  ZBM  (BIOS/MBR): BIOS -> MBR -> VBR -> Stage2 -> ZBM -> kernel"
	@echo "  ZBM  (UEFI/GPT): UEFI -> ESP -> BOOT*.EFI -> ZBM -> kernel"
	@echo "  AArch64 (UEFI):  EDK2 nightly -> ESP -> BOOTAA64.EFI -> kernel"
	@echo "  RISC-V64 (UEFI): VIRT.fd -> virtio ESP -> BOOTRISCV64.EFI -> kernel（GNU-EFI 链接 ZBM）"
	@echo "  LoongArch64:     仅 ZBM+UEFI（ESP）；BOOT_METHOD=mbr 时 QEMU -kernel 直启（开发）"

# ══════════════════════════════════════════════════════
#  Build kernel
# ══════════════════════════════════════════════════════

build:
	@echo "[ZirconOS] Building kernel (arch=$(ARCH), optimize=$(OPTIMIZE), desktop=$(DESKTOP))..."
	@mkdir -p $(TMP_DIR)/kernel-prefix $(TMP_DIR)/zig-cache
	cd $(ROOT_DIR) && zig build \
		-Doptimize=$(OPTIMIZE) \
		-Darch=$(ARCH) \
		-Ddebug=$(DEBUG_LOG) \
		-Dmouse_debug=$(MOUSE_DEBUG) \
		-Dagent_ndjson=$(AGENT_NDJSON) \
		-Denable_idt=$(ENABLE_IDT) \
		-Damd_igpu=$(AMD_IGPU) \
		-Damd_igpu_defer_probe=$(AMD_IGPU_DEFER_PROBE) \
		-Damd_kms_experimental=$(AMD_KMS_EXPERIMENTAL) \
		-Dintel_igpu=$(INTEL_IGPU) \
		-Dintel_igpu_defer_probe=$(INTEL_IGPU_DEFER_PROBE) \
		-Dintel_kms_experimental=$(INTEL_KMS_EXPERIMENTAL) \
		-Dloongson_igpu=$(LOONGSON_IGPU) \
		-Dloongson_igpu_defer_probe=$(LOONGSON_IGPU_DEFER_PROBE) \
		-Dloongson_kms_experimental=$(LOONGSON_KMS_EXPERIMENTAL) \
		-Ddesktop_idle_spin=$(DESKTOP_IDLE_SPIN) \
		-Ddefault_desktop=$(DESKTOP) \
		--cache-dir $(TMP_DIR)/zig-cache \
		--prefix $(TMP_DIR)/kernel-prefix
	@echo "[ZirconOS] Stripping debug sections..."
ifeq ($(ARCH),loongarch64)
	@cp -f $(KERNEL_ELF_DEBUG) $(KERNEL_ELF)
	@echo "[ZirconOS] (loongarch64: copied ELF; --strip-debug skipped: host objcopy/zig objcopy lack full support)"
else
	@objcopy --strip-debug $(KERNEL_ELF_DEBUG) $(KERNEL_ELF) 2>/dev/null || \
		cp -f $(KERNEL_ELF_DEBUG) $(KERNEL_ELF)
endif
	@echo "[ZirconOS] Kernel: $(KERNEL_ELF)"

build-release:
	@$(MAKE) build OPTIMIZE=ReleaseSafe

# ══════════════════════════════════════════════════════
#  Build desktop theme
# ══════════════════════════════════════════════════════

build-desktop:
	@echo "[ZirconOS] Building desktop theme: $(DESKTOP) (EXE + LIB + DLL)..."
	@if [ "$(DESKTOP)" = "none" ]; then \
		echo "[ZirconOS] DESKTOP=none, skipping desktop build"; \
	elif [ -d "$(THEME_DIR)" ]; then \
		cd $(THEME_DIR) && zig build -Doptimize=$(OPTIMIZE) && \
		cd $(THEME_DIR) && zig build dll -Doptimize=$(OPTIMIZE); \
	else \
		echo "[ZirconOS] Theme directory not found: $(THEME_DIR)"; \
	fi

build-desktop-all:
	@echo "[ZirconOS] Building all desktop themes (EXE + LIB + DLL)..."
	@for theme in classic luna aero modern fluent sunvalley; do \
		dir="$(ROOT_DIR)/src/desktop/$$theme"; \
		if [ -d "$$dir" ]; then \
			echo "[ZirconOS]   Building $$theme..."; \
			cd "$$dir" && zig build -Doptimize=$(OPTIMIZE) && \
			cd "$$dir" && zig build dll -Doptimize=$(OPTIMIZE); \
		else \
			echo "[ZirconOS]   Skipping $$theme (not found: $$dir)"; \
		fi; \
	done

build-desktop-dll:
	@echo "[ZirconOS] Building desktop theme DLL: $(DESKTOP)..."
	@if [ "$(DESKTOP)" = "none" ]; then \
		echo "[ZirconOS] DESKTOP=none, skipping DLL build"; \
	elif [ -d "$(THEME_DIR)" ]; then \
		cd $(THEME_DIR) && zig build dll -Doptimize=$(OPTIMIZE); \
	else \
		echo "[ZirconOS] Theme directory not found: $(THEME_DIR)"; \
	fi

# ══════════════════════════════════════════════════════
#  ZBM UEFI Boot Application
# ══════════════════════════════════════════════════════

build-zbm-uefi:
ifeq ($(ARCH),loongarch64)
	@$(MAKE) build-zbm-loongarch-uefi
else ifeq ($(ARCH),riscv64)
	@$(MAKE) build-zbm-riscv64-uefi
else
	@echo "[ZirconOS] Building ZBM UEFI boot application..."
	@mkdir -p $(UEFI_PREFIX) $(UEFI_CACHE)
	cd $(ROOT_DIR) && zig build uefi \
		-Doptimize=$(OPTIMIZE) \
		-Darch=$(ARCH) \
		-Ddesktop=$(DESKTOP) \
		--cache-dir $(UEFI_CACHE) \
		--prefix $(UEFI_PREFIX)
	@echo "[ZirconOS] UEFI app: $(UEFI_EFI)"
endif

# LoongArch UEFI：默认 C stub（稳定）；Zig stub 有 INE 异常，LOONGARCH64_USE_C_STUB=0 时用 Zig
LOONGARCH64_USE_C_STUB ?= 1

# Zig stub：main_loongarch64.zig + linker_stub.lds（与 C stub 同流程），固件可加载
build-zbm-loongarch64-stub:
	@echo "[ZirconOS] LoongArch UEFI: Building Zig ZBM stub (AevOS-style)..."
	@mkdir -p $(TMP_DIR)
	@$(MAKE) build ARCH=loongarch64
	@bash $(ROOT_DIR)/scripts/build/build-zbm-loongarch64-stub.sh "$(ZBM_LOONGARCH64_EFI)"

# C stub：无 gnu-efi，与 AevOS 相同构建流程，QEMU_EFI.fd 可加载
build-stub-loongarch64:
	@echo "[ZirconOS] LoongArch UEFI: Building C stub (AevOS-style)..."
	@mkdir -p $(TMP_DIR)
	@bash $(ROOT_DIR)/scripts/build/build-stub-loongarch64.sh "$(ZBM_LOONGARCH64_EFI)"

# Zig ZBM：GNU-EFI 链接，部分 QEMU_EFI.fd 报 Unsupported
build-zbm-loongarch-uefi:
	@echo "[ZirconOS] LoongArch ZBM UEFI: GNU-EFI link $(ZBM_LOONGARCH64_O) → $(ZBM_LOONGARCH64_EFI)"
	@test -f "$(ZBM_LOONGARCH64_O)" || { echo "[ZirconOS] ERROR: missing $(ZBM_LOONGARCH64_O). Run: make build ARCH=loongarch64" >&2; exit 1; }
	@if [ ! -f "$(ROOT_DIR)/gnu-efi/loongarch64-built/crt0-efi-loongarch64.o" ]; then \
		echo "[ZirconOS] 首次需要 GNU-EFI（LoongArch），正在执行 fetch-gnu-efi …"; \
		$(MAKE) fetch-gnu-efi; \
	fi
	@bash $(ROOT_DIR)/scripts/build/zbm-loongarch64-efi.sh "$(ZBM_LOONGARCH64_O)" "$(ZBM_LOONGARCH64_EFI)"

# RISC-V64：Zig 仅生成 .o，GNU-EFI（ncroxon）链接为 BOOTRISCV64.EFI
build-zbm-riscv64-uefi:
	@echo "[ZirconOS] RISC-V64 ZBM: GNU-EFI link $(ZBM_RISCV64_O) → $(ZBM_RISCV64_EFI)"
	@test -f "$(ZBM_RISCV64_O)" || { echo "[ZirconOS] ERROR: missing $(ZBM_RISCV64_O). Run: make build ARCH=riscv64" >&2; exit 1; }
	@if [ ! -f "$(ROOT_DIR)/gnu-efi/riscv64-built/crt0-efi-riscv64.o" ]; then \
		echo "[ZirconOS] 首次需要 GNU-EFI（RISC-V），执行 fetch-gnu-efi-riscv64 …"; \
		bash $(ROOT_DIR)/scripts/build/fetch-gnu-efi-riscv64.sh || exit 1; \
	fi
	@bash $(ROOT_DIR)/scripts/build/zbm-riscv64-efi.sh "$(ZBM_RISCV64_O)" "$(ZBM_RISCV64_EFI)"

# ══════════════════════════════════════════════════════
#  ZBM BIOS Boot Components (MBR + VBR + Stage2)
# ══════════════════════════════════════════════════════

build-zbm-bios:
	@echo "[ZirconOS] Building ZBM BIOS components..."
	@mkdir -p $(ZBM_DIR)
	as --32 -o $(ZBM_DIR)/mbr.o $(ZBM_SRC_DIR)/mbr.s
	ld -m elf_i386 -T $(ROOT_DIR)/link/mbr.ld -o $(ZBM_DIR)/mbr.elf $(ZBM_DIR)/mbr.o 2>/dev/null || true
	objcopy -O binary $(ZBM_DIR)/mbr.o $(ZBM_DIR)/mbr.bin
	truncate -s 512 $(ZBM_DIR)/mbr.bin
	@echo "[ZirconOS] MBR: $(ZBM_DIR)/mbr.bin"
	as --32 -o $(ZBM_DIR)/vbr.o $(ZBM_SRC_DIR)/vbr.s
	ld -m elf_i386 -T $(ROOT_DIR)/link/vbr.ld -o $(ZBM_DIR)/vbr.elf $(ZBM_DIR)/vbr.o 2>/dev/null || true
	objcopy -O binary $(ZBM_DIR)/vbr.o $(ZBM_DIR)/vbr.bin
	truncate -s 512 $(ZBM_DIR)/vbr.bin
	@echo "[ZirconOS] VBR: $(ZBM_DIR)/vbr.bin"
	as --32 -o $(ZBM_DIR)/stage2.o $(ZBM_SRC_DIR)/stage2.s
	ld -m elf_i386 -T $(ROOT_DIR)/link/zbm_bios.ld -o $(ZBM_DIR)/stage2.elf $(ZBM_DIR)/stage2.o 2>/dev/null || true
	objcopy -O binary $(ZBM_DIR)/stage2.o $(ZBM_DIR)/stage2.bin
	@echo "[ZirconOS] Stage2: $(ZBM_DIR)/stage2.bin"
	cd $(ROOT_DIR) && zig build zbm \
		-Doptimize=ReleaseSmall \
		-Darch=x86_64 \
		--cache-dir $(TMP_DIR)/zig-cache \
		--prefix $(TMP_DIR)/kernel-prefix 2>/dev/null || true
	@echo "[ZirconOS] ZBM BIOS components built"

# ══════════════════════════════════════════════════════
#  ZBM Disk Images (MBR + GPT)
# ══════════════════════════════════════════════════════

build-zbm-disk: build-zbm-bios build
	@echo "[ZirconOS] Building ZBM disk images (128 MB)..."
	@mkdir -p $(BUILD_DIR)
	dd if=/dev/zero of=$(ZBM_DISK_MBR) bs=1M count=128 status=none
	dd if=$(ZBM_DIR)/mbr.bin of=$(ZBM_DISK_MBR) bs=512 count=1 conv=notrunc status=none
	@python3 -c "\
	import struct; \
	entry = struct.pack('<BBBBBBBBII', \
	    0x80, 0x00, 0x21, 0x00, \
	    0xFE, 0xFE, 0xFF, 0xFF, \
	    2048, (128*1024*1024//512)-2048); \
	f = open('$(ZBM_DISK_MBR)', 'r+b'); \
	f.seek(446); f.write(entry); f.close()" 2>/dev/null || true
	dd if=$(ZBM_DIR)/vbr.bin of=$(ZBM_DISK_MBR) bs=512 seek=2048 count=1 conv=notrunc status=none
	dd if=$(ZBM_DIR)/stage2.bin of=$(ZBM_DISK_MBR) bs=512 seek=2049 conv=notrunc status=none
	dd if=$(KERNEL_ELF) of=$(ZBM_DISK_MBR) bs=512 seek=2113 conv=notrunc status=none
	@echo "[ZirconOS] MBR disk: $(ZBM_DISK_MBR)"
	@if command -v sgdisk >/dev/null 2>&1; then \
		dd if=/dev/zero of=$(ZBM_DISK_GPT) bs=1M count=128 status=none; \
		sgdisk --clear $(ZBM_DISK_GPT) >/dev/null 2>&1; \
		sgdisk -n 1:2048:67583 -t 1:EF00 -c 1:"EFI System" $(ZBM_DISK_GPT) >/dev/null 2>&1; \
		sgdisk -n 2:67584:0 -t 2:8300 -c 2:"ZirconOS System" $(ZBM_DISK_GPT) >/dev/null 2>&1; \
		dd if=$(ZBM_DIR)/stage2.bin of=$(ZBM_DISK_GPT) bs=512 seek=34 conv=notrunc status=none; \
		echo "[ZirconOS] GPT disk: $(ZBM_DISK_GPT)"; \
	else \
		echo "[ZirconOS] sgdisk not found, skipping GPT (apt install gdisk)"; \
	fi

# ══════════════════════════════════════════════════════
#  ESP (EFI System Partition) Image
# ══════════════════════════════════════════════════════

build-esp: build
ifneq ($(ARCH),loongarch64)
	@$(MAKE) build-zbm-uefi DESKTOP=$(DESKTOP)
else
	@if [ "$(LOONGARCH64_USE_C_STUB)" = "1" ]; then \
		$(MAKE) build-stub-loongarch64; \
	else \
		$(MAKE) build-zbm-loongarch64-stub; \
	fi
endif
	@echo "[ZirconOS] Building ESP image (arch=$(ARCH))..."
ifeq ($(ARCH),loongarch64)
	@ZIRCON_BUILD_TMP="$(TMP_DIR)" BOOTLOADER=$(BOOTLOADER) \
		ZBM_LOONGARCH64_EFI="$(ZBM_LOONGARCH64_EFI)" \
		bash $(ROOT_DIR)/scripts/build/mkesp-loongarch64.sh "$(ESP_IMG)" "$(KERNEL_ELF)" "$(ZBM_LOONGARCH64_EFI)"
else
	dd if=/dev/zero of=$(ESP_IMG) bs=1M count=64 status=none
	mformat -i $(ESP_IMG) ::
	mmd -i $(ESP_IMG) ::/EFI
	mmd -i $(ESP_IMG) ::/EFI/BOOT
ifeq ($(ARCH),aarch64)
	mcopy -i $(ESP_IMG) $(UEFI_EFI) ::/EFI/BOOT/BOOTAA64.EFI
else ifeq ($(ARCH),riscv64)
	mcopy -i $(ESP_IMG) $(UEFI_EFI) ::/EFI/BOOT/BOOTRISCV64.EFI
else
	mcopy -i $(ESP_IMG) $(UEFI_EFI) ::/EFI/BOOT/BOOTX64.EFI
endif
	@if [ -f "$(KERNEL_ELF)" ]; then \
		mmd -i $(ESP_IMG) ::/boot 2>/dev/null || true; \
		mcopy -i $(ESP_IMG) $(KERNEL_ELF) ::/boot/kernel.elf 2>/dev/null || true; \
	fi
endif
	@echo "[ZirconOS] ESP image: $(ESP_IMG)"

# ══════════════════════════════════════════════════════
#  ISO (UEFI only — embedded FAT ESP + xorriso; no GRUB)
# ══════════════════════════════════════════════════════

iso: build
ifneq ($(ARCH),x86_64)
	$(error iso target is implemented for ARCH=x86_64 UEFI ISO only; use build-esp + QEMU for $(ARCH))
endif
	@echo "[ZirconOSAero] Building UEFI ISO (ZBM, desktop=$(DESKTOP))..."
	@$(MAKE) build-zbm-uefi
	@test -f "$(UEFI_EFI)" || { echo "[ZirconOSAero] missing $(UEFI_EFI) (zig build uefi failed?)" >&2; exit 1; }
	@mkdir -p $(RELEASE_DIR)
	bash $(ROOT_DIR)/scripts/build/mkiso-uefi-zbm.sh "$(ISO)" "$(KERNEL_ELF)" "$(UEFI_EFI)"
	@echo "[ZirconOSAero] ISO: $(ISO)"

# ══════════════════════════════════════════════════════
#  run: unified entry point driven by build.conf
# ══════════════════════════════════════════════════════

run:
ifeq ($(ARCH),aarch64)
	@$(MAKE) run-aarch64 ARCH=aarch64
else ifeq ($(ARCH),riscv64)
	@$(MAKE) run-riscv64 ARCH=riscv64
else ifeq ($(ARCH),loongarch64)
	@$(MAKE) run-loongarch64 ARCH=loongarch64
else
ifeq ($(BOOT_METHOD),uefi)
	@$(MAKE) _run-zbm-uefi
else
	@$(MAKE) _run-zbm-bios
endif
endif

# ── ZBM + BIOS ──
_run-zbm-bios: build-zbm-disk
	@echo "[ZirconOS] BIOS + ZBM → $(DESKTOP) Desktop ($(QEMU_MEM))..."
	qemu-system-x86_64 \
		-drive format=raw,file=$(ZBM_DISK_MBR) \
		$(QEMU_COMMON)

# ── ZBM + UEFI ──
_run-zbm-uefi: build-esp
	@echo "[ZirconOS] UEFI + ZBM → $(DESKTOP) Desktop ($(QEMU_MEM))..."
	@mkdir -p $(TMP_DIR)
	@cp -f $(OVMF_VARS) $(TMP_DIR)/OVMF_VARS.fd
	qemu-system-x86_64 \
		-drive if=pflash,format=raw,readonly=on,file=$(OVMF_CODE) \
		-drive if=pflash,format=raw,file=$(TMP_DIR)/OVMF_VARS.fd \
		-drive format=raw,file=$(ESP_IMG) \
		$(QEMU_COMMON_X86)

# ── Debug mode (GDB) — ZBM MBR disk (same kernel path as build-zbm-disk) ──
run-debug: build-zbm-disk
	@echo "[ZirconOSAero] Debug mode (GDB on :1234), ZBM MBR disk..."
	qemu-system-x86_64 \
		-drive format=raw,file=$(ZBM_DISK_MBR) \
		$(QEMU_COMMON) \
		-s -S

# ══════════════════════════════════════════════════════
#  AArch64 boot (EDK2 nightly firmware)
# ══════════════════════════════════════════════════════

run-aarch64: build-esp
	@echo "[ZirconOS] AArch64 UEFI boot (EDK2 nightly firmware)..."
	@if [ ! -f "$(AARCH64_EFI_CODE)" ]; then \
		echo "[ZirconOS] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	@mkdir -p $(TMP_DIR)
	@echo "[ZirconOS] Padding AArch64 pflash to $(AARCH64_PFLASH_MB)MiB (QEMU virt requirement)..."
	@dd if=/dev/zero of=$(TMP_DIR)/AARCH64_PFLASH0.fd bs=1M count=$(AARCH64_PFLASH_MB) status=none
	@dd if=$(AARCH64_EFI_CODE) of=$(TMP_DIR)/AARCH64_PFLASH0.fd conv=notrunc status=none
	@dd if=/dev/zero of=$(TMP_DIR)/AARCH64_PFLASH1.fd bs=1M count=$(AARCH64_PFLASH_MB) status=none
	@dd if=$(AARCH64_EFI_VARS) of=$(TMP_DIR)/AARCH64_PFLASH1.fd conv=notrunc status=none
	qemu-system-aarch64 \
		$(QEMU_COMMON_AARCH64) \
		-drive if=pflash,format=raw,readonly=on,file=$(TMP_DIR)/AARCH64_PFLASH0.fd \
		-drive if=pflash,format=raw,file=$(TMP_DIR)/AARCH64_PFLASH1.fd \
		$(QEMU_AARCH64_DEVICES)

run-aarch64-debug: build-esp
	@echo "[ZirconOS] AArch64 debug mode (GDB on :1234)..."
	@if [ ! -f "$(AARCH64_EFI_CODE)" ]; then \
		echo "[ZirconOS] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	@mkdir -p $(TMP_DIR)
	@echo "[ZirconOS] Padding AArch64 pflash to $(AARCH64_PFLASH_MB)MiB (QEMU virt requirement)..."
	@dd if=/dev/zero of=$(TMP_DIR)/AARCH64_PFLASH0.fd bs=1M count=$(AARCH64_PFLASH_MB) status=none
	@dd if=$(AARCH64_EFI_CODE) of=$(TMP_DIR)/AARCH64_PFLASH0.fd conv=notrunc status=none
	@dd if=/dev/zero of=$(TMP_DIR)/AARCH64_PFLASH1.fd bs=1M count=$(AARCH64_PFLASH_MB) status=none
	@dd if=$(AARCH64_EFI_VARS) of=$(TMP_DIR)/AARCH64_PFLASH1.fd conv=notrunc status=none
	qemu-system-aarch64 \
		$(QEMU_COMMON_AARCH64) \
		-drive if=pflash,format=raw,readonly=on,file=$(TMP_DIR)/AARCH64_PFLASH0.fd \
		-drive if=pflash,format=raw,file=$(TMP_DIR)/AARCH64_PFLASH1.fd \
		$(QEMU_AARCH64_DEVICES) \
		-s -S

# ══════════════════════════════════════════════════════
#  RISC-V64 boot (EDK2 VIRT firmware + virtio ESP)
# ══════════════════════════════════════════════════════

run-riscv64: build-esp
	@echo "[ZirconOS] RISC-V64 UEFI boot ($(RISCV64_EFI_CODE))..."
	@if [ ! -f "$(RISCV64_EFI_CODE)" ]; then \
		echo "[ZirconOS] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	qemu-system-riscv64 \
		$(QEMU_COMMON_RISCV64) \
		-bios $(RISCV64_EFI_CODE) \
		-drive if=none,id=zircon-esp0,file=$(ESP_IMG),format=raw \
		-device virtio-blk-pci,drive=zircon-esp0,bootindex=0 \
		$(QEMU_RISCV64_EXTRA)

run-riscv64-debug: build-esp
	@echo "[ZirconOS] RISC-V64 UEFI debug (GDB on :1234)..."
	@if [ ! -f "$(RISCV64_EFI_CODE)" ]; then \
		echo "[ZirconOS] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	qemu-system-riscv64 \
		$(QEMU_COMMON_RISCV64) \
		-bios $(RISCV64_EFI_CODE) \
		-drive if=none,id=zircon-esp0,file=$(ESP_IMG),format=raw \
		-device virtio-blk-pci,drive=zircon-esp0,bootindex=0 \
		$(QEMU_RISCV64_EXTRA) \
		-s -S

# ══════════════════════════════════════════════════════
#  LoongArch64 boot (EDK2 nightly firmware)
# ══════════════════════════════════════════════════════

# run-loongarch64：默认 UEFI + build/esp-loongarch64.img（含 startup.nsh）→ Shell 倒计时后自动进入 ZBM；kernel 模式为 -kernel 直启。
run-loongarch64:
ifeq ($(LOONGARCH64_QEMU_MODE),kernel)
	@$(MAKE) build ARCH=loongarch64
	@echo "[ZirconOS] LoongArch64 QEMU: -kernel $(KERNEL_ELF) + ramfb（Aero 桌面）"
	@echo "[ZirconOS] 若 QEMU 持续显示 'Guest has not initialized the display'，可尝试: make run-loongarch64 LOONGARCH64_QEMU_MODE=uefi（需固件）"
	qemu-system-loongarch64 $(QEMU_LOONGARCH64_BASE) \
		-kernel $(KERNEL_ELF) \
		-device ramfb,id=zircon_ramfb
else ifeq ($(LOONGARCH64_QEMU_MODE),uefi)
	@$(MAKE) build-esp ARCH=loongarch64 DESKTOP=$(DESKTOP)
	@echo "[ZirconOS] LoongArch64 UEFI + ZBM — $(LOONGARCH64_EFI_CODE)"
	@if [ ! -f "$(LOONGARCH64_EFI_CODE)" ]; then \
		echo "[ZirconOS] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	@echo "[ZirconOS] 等待内置 Shell 的 startup.nsh 倒计时结束（勿按 ESC）后将进入 ZBM 菜单；串口与 QEMU 窗口均可查看 ConOut。"
	@echo "[ZirconOS] 键盘操作：请先点击 QEMU 窗口使其获得焦点，再用方向键/数字键选择启动项。"
	qemu-system-loongarch64 $(QEMU_LOONGARCH64_BASE) \
		-bios $(LOONGARCH64_EFI_CODE) \
		$(QEMU_LOONGARCH64_DEVICES) \
		-boot order=d
else
	$(error LOONGARCH64_QEMU_MODE must be kernel or uefi (got $(LOONGARCH64_QEMU_MODE)))
endif

# 与 LOONGARCH64_QEMU_MODE=uefi 相同（保留别名）；需 QEMU_EFI.fd、build-esp（含 startup.nsh → ZBM）。
run-loongarch64-autozbm:
	@$(MAKE) run-loongarch64 ARCH=loongarch64 LOONGARCH64_QEMU_MODE=uefi

run-loongarch64-debug:
ifeq ($(LOONGARCH64_QEMU_MODE),kernel)
	@$(MAKE) build ARCH=loongarch64
	@echo "[ZirconOS] LoongArch64 debug: -kernel + ramfb + GDB :1234"
	qemu-system-loongarch64 $(QEMU_LOONGARCH64_BASE) \
		-kernel $(KERNEL_ELF) -device ramfb,id=zircon_ramfb -s -S
else ifeq ($(LOONGARCH64_QEMU_MODE),uefi)
	@$(MAKE) build-esp ARCH=loongarch64 DESKTOP=$(DESKTOP)
	@echo "[ZirconOS] LoongArch64 UEFI debug (GDB on :1234)..."
	@if [ ! -f "$(LOONGARCH64_EFI_CODE)" ]; then \
		echo "[ZirconOS] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	@echo "[ZirconOS] 若需手动：fs0: → cd \\EFI\\BOOT → BOOTLOONGARCH64.EFI"
	qemu-system-loongarch64 $(QEMU_LOONGARCH64_BASE) \
		-bios $(LOONGARCH64_EFI_CODE) \
		$(QEMU_LOONGARCH64_DEVICES) \
		-boot order=d \
		-s -S
else
	$(error LOONGARCH64_QEMU_MODE must be kernel or uefi (got $(LOONGARCH64_QEMU_MODE)))
endif

# ══════════════════════════════════════════════════════
#  Resources / Fonts / Themes
# ══════════════════════════════════════════════════════

fonts:
	@if [ -x $(ROOT_DIR)/scripts/fonts/fetch-fonts.sh ]; then \
		$(ROOT_DIR)/scripts/fonts/fetch-fonts.sh; \
	else \
		echo "[ZirconOS] $(ROOT_DIR)/scripts/fonts/fetch-fonts.sh not found"; \
	fi

resources:
	@echo "[ZirconOS] Resources for $(DESKTOP) theme:"
	@if [ -n "$(THEME_DIR)" ] && [ -d "$(THEME_DIR)/resources" ]; then \
		echo "  Wallpapers:"; \
		ls -1 $(THEME_DIR)/resources/wallpapers/*.svg 2>/dev/null | sed 's/.*\//    /' || echo "    (none)"; \
		echo "  Icons:"; \
		ls -1 $(THEME_DIR)/resources/icons/*.svg 2>/dev/null | sed 's/.*\//    /' || echo "    (none)"; \
		echo "  Cursors:"; \
		ls -1 $(THEME_DIR)/resources/cursors/*.svg 2>/dev/null | sed 's/.*\//    /' || echo "    (none)"; \
		echo "  Themes:"; \
		ls -1 $(THEME_DIR)/resources/themes/*.theme 2>/dev/null | sed 's/.*\//    /' || echo "    (none)"; \
	else \
		echo "  (theme directory not found)"; \
	fi

fetch-themes:
	@echo "[ZirconOS] 桌面主题与资源: src/desktop/<主题>/resources/，共享字体: src/fonts/"

# GNU-EFI（LoongArch ZBM 链接所需 crt0/lds → gnu-efi/loongarch64-built/）
fetch-gnu-efi:
	@echo "[ZirconOS] Fetching GNU-EFI (for LoongArch BOOTLOONGARCH64.EFI link)..."
	@bash $(ROOT_DIR)/scripts/build/fetch-gnu-efi.sh "$(ROOT_DIR)/gnu-efi/loongarch64-built"

fetch-gnu-efi-riscv64:
	@echo "[ZirconOS] Fetching GNU-EFI (ncroxon, RISC-V64 BOOTRISCV64.EFI link)..."
	@bash $(ROOT_DIR)/scripts/build/fetch-gnu-efi-riscv64.sh "$(ROOT_DIR)/gnu-efi/riscv64-built"

# ── Firmware (EDK2 nightly from https://retrage.github.io/edk2-nightly/) ──
fetch-firmware:
	@echo "[ZirconOS] Downloading EDK2 nightly firmware..."
	@bash $(ROOT_DIR)/scripts/build/fetch-firmware.sh $(FIRMWARE_DIR)

# LoongArch 默认可移动介质引导名 \EFI\BOOT\BOOTLOONGARCH64.EFI（无则固件直接进 Shell）
fetch-loongarch-boot-efi:
	@echo "[ZirconOS] Downloading BOOTLOONGARCH64.EFI (EDK2 RELEASE Shell → standard boot path)..."
	@mkdir -p $(FIRMWARE_DIR)
	curl -fSL -o $(FIRMWARE_DIR)/BOOTLOONGARCH64.EFI \
		https://retrage.github.io/edk2-nightly/bin/RELEASELOONGARCH64_Shell.efi
	@echo "[ZirconOS] Installed: $(FIRMWARE_DIR)/BOOTLOONGARCH64.EFI"

# ══════════════════════════════════════════════════════
#  Tests
# ══════════════════════════════════════════════════════

test: test-kernel test-config test-boot
	@echo "[ZirconOS] All tests complete."

test-kernel: build
	@echo "[ZirconOS] Running kernel verification tests..."
	@mkdir -p $(TEST_RESULTS_DIR)
	python3 $(ROOT_DIR)/tests/run_all.py \
		--kernel $(KERNEL_ELF) \
		--output-dir $(TEST_RESULTS_DIR)

# 无头 QEMU 烟测（需已安装 qemu-system-x86_64）；串口字节数见脚本输出。
smoke-qemu-mbr:
	@bash $(ROOT_DIR)/scripts/smoke-qemu-mbr.sh

test-config:
	@echo "[ZirconOS] Running build configuration tests..."
	@mkdir -p $(TEST_RESULTS_DIR)
	python3 $(ROOT_DIR)/tests/test_build_config.py \
		--project-root $(ROOT_DIR) \
		--output-dir $(TEST_RESULTS_DIR)

test-boot:
	@echo "[ZirconOS] Running boot combination tests..."
	@mkdir -p $(TEST_RESULTS_DIR)
	python3 $(ROOT_DIR)/tests/test_boot_combinations.py \
		--project-root $(ROOT_DIR) \
		--output-dir $(TEST_RESULTS_DIR)

# ══════════════════════════════════════════════════════
#  Clean
# ══════════════════════════════════════════════════════

clean:
	@echo "[ZirconOS] Cleaning..."
	rm -rf $(BUILD_DIR)
	rm -rf $(ROOT_DIR)/.zig-cache $(ROOT_DIR)/zig-out
	@for theme in classic luna aero modern fluent sunvalley; do \
		dir="$(ROOT_DIR)/src/desktop/$$theme"; \
		[ -d "$$dir" ] && rm -rf "$$dir/.zig-cache" "$$dir/zig-out" 2>/dev/null; \
	done || true
	@echo "[ZirconOS] Clean done"
