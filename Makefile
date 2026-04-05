# ZirconOSAero — NT 6.1 (Windows 7) style hybrid microkernel OS (Zig)
# Build system reads build.conf. Override: make DESKTOP=aero BOOT_METHOD=uefi
#
# Requires: zig, qemu-system-* (per ARCH), OVMF/EDK2 firmware, xorriso, mtools, dosfstools

.PHONY: all build build-release iso iso-debug iso-release run run-debug run-qemu-1to1 run-qemu-zoom-fit run-qemu-sdl \
	build-zbm-uefi build-zbm-loongarch-uefi build-zbm-riscv64-uefi build-zbm-loongarch64-stub build-zbm-bios build-zbm-disk build-esp \
	build-desktop build-desktop-all build-desktop-dll \
	fetch-themes fetch-firmware fetch-gnu-efi fetch-gnu-efi-riscv64 fetch-loongarch-boot-efi fonts resources fetch-assets \
	run-fb-large run-aarch64 run-riscv64 run-loongarch64 run-loongarch64-autozbm run-loongarch64-serial-debug run-aarch64-debug run-riscv64-debug run-loongarch64-debug \
	test test-kernel test-config test-boot test-all smoke-qemu-mbr \
	clean help show-config configure sync-resolution

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
# 未在 build.conf 中写 RESOLUTION 时的回退（-include 之后仍为空才生效）
RESOLUTION   ?= 1920x1080x32
# 显示用 WxH（与 RESOLUTION / sync 产物一致）
ZBM_RES_W    := $(word 1,$(subst x, ,$(RESOLUTION)))
ZBM_RES_H    := $(word 2,$(subst x, ,$(RESOLUTION)))
QEMU_MEM     ?= 512M
# LoongArch：`make run-loongarch64` 使用 **QEMU_MEM_LOONGARCH64**，**不**读取本行的 QEMU_MEM。
# build.conf 里的 QEMU_MEM=8G 仅影响 x86_64 / AArch64 / RISC-V 等使用 $(QEMU_MEM) 的目标；若要让 LoongArch 客体内存变大，请在 build.conf 或命令行设置 QEMU_MEM_LOONGARCH64（须 >1G，EDK2 virt 要求）。
# qemu-system-loongarch64 -M virt + EDK2: guest RAM must be strictly > 1G (else: ram_size must be greater than 1G).
QEMU_MEM_LOONGARCH64 ?= 1536M
ENABLE_IDT   ?= true
DEBUG_LOG    ?= true
# 鼠标诊断：串口/控制台 [MOUSEDBG] + 底栏显示 ptr x,y（不依赖 DEBUG_LOG）
MOUSE_DEBUG  ?= false
# 桌面合成 bisect：zig build -Ddesktop_bisect=true 等效；panic 行尾 [phase=0x…] 见 rtl/panic_context.zig
DESKTOP_BISECT ?= false
# 高分 QEMU：减轻盒式模糊默认半径/遍数（zig build -Daero_blur_light=true）
AERO_BLUR_LIGHT ?= false
# GTK：默认 1:1 像素，QEMU 客户区随 build.conf RESOLUTION 与客体扫描分辨率对齐（嫌窗口过大可 `make run-qemu-zoom-fit`）
QEMU_GTK_ZOOM ?= zoom-to-fit=off
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
# x86_64：NVIDIA 10DE 显示类 PCI/MMIO + GOP handoff（nouveau 风格阶段一；QEMU pc + -vga std 无 10de，见 QEMU_COMMON_X86 注释）
NVIDIA_GPU ?= true
NVIDIA_GPU_DEFER_PROBE ?= false
NVIDIA_KMS_EXPERIMENTAL ?= false
# 混合显卡时默认 false：不向 HDMI 桩写主连接器，避免覆盖 Intel/AMD 元数据；单 NVIDIA 可 make NVIDIA_HDMI_SYNC=true
NVIDIA_HDMI_SYNC ?= false
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

# Bootloader: ZBM only
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
# `make` / `make run-debug`：整次会话输出覆盖写入此文件（非追加）。嵌套 make 请传 ZIRCON_NO_LOG=1 或已由内层自动设置。
LOG_TXT      := $(ROOT_DIR)/.log/log.txt
BUILD_DIR    := $(ROOT_DIR)/build
TMP_DIR      := $(BUILD_DIR)/tmp
RELEASE_DIR  := $(BUILD_DIR)/release

# sync_resolution：仅命令行 / 环境覆盖 RESOLUTION 时传 ZIRCON_RESOLUTION；否则脚本只读 build.conf（避免日志误报 from ZIRCON_RESOLUTION）
SYNC_RESOLUTION_CMD = if [ "$(origin RESOLUTION)" = "command line" ] || [ "$(origin RESOLUTION)" = "environment" ]; then ZIRCON_RESOLUTION="$(RESOLUTION)" python3 $(ROOT_DIR)/scripts/sync_resolution_config.py; else python3 $(ROOT_DIR)/scripts/sync_resolution_config.py; fi

KERNEL_ELF_DEBUG := $(TMP_DIR)/kernel-prefix/bin/kernel
KERNEL_ELF       := $(TMP_DIR)/kernel.elf
# UEFI 可启动 ISO：debug = 串口 + 屏幕 klog；release = ReleaseSafe + 无屏幕文本日志（便于后续开机动画）
ISO_DEBUG        := $(RELEASE_DIR)/zirconos-$(VERSION)-uefi-$(ARCH)-debug.iso
ISO_RELEASE      := $(RELEASE_DIR)/zirconos-$(VERSION)-uefi-$(ARCH)-release.iso
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
# Debug + desktop=aero 时 kernel.elf 常远超 64MiB；ESP 过小会导致 mcopy 报 Disk full 且 ZBM 找不到内核。
ESP_IMG_MB       ?= 256
# run-aarch64 / run-riscv64 在子 make 中按 ARCH 构建 ESP，但父进程 ARCH 可能仍为 x86_64；QEMU 驱动须用固定路径。
ESP_IMG_AARCH64  := $(BUILD_DIR)/esp-aarch64.img
ESP_IMG_RISCV64  := $(BUILD_DIR)/esp-riscv64.img
# Fixed path for LoongArch QEMU (avoid := expansion when ARCH defaults to x86_64 but target is run-loongarch64).
ESP_IMG_LOONGARCH64 := $(BUILD_DIR)/esp-loongarch64.img
ZBM_DISK_MBR     := $(BUILD_DIR)/zirconos-mbr.img
ZBM_DISK_GPT     := $(BUILD_DIR)/zirconos-gpt.img

# 仓库内仅包含 `src/desktop/aero`；其它 DESKTOP 值保留为将来主题目录名（无目录则 build-desktop 跳过）。
FONTS_DIR                := $(ROOT_DIR)/src/fonts
THEME_DIR                := $(ROOT_DIR)/src/desktop/$(DESKTOP)

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
# x86：默认 gtk；`make run-qemu-sdl` 或 `QEMU_DISPLAY_BACKEND=sdl` 使用 SDL（窗口缩放与 GTK 不同，便于对照）。
QEMU_DISPLAY_BACKEND ?= gtk
ifeq ($(QEMU_DISPLAY_BACKEND),sdl)
QEMU_X86_VIDEO_FLAGS := -display sdl -vga std
else
QEMU_X86_VIDEO_FLAGS := -display gtk,$(QEMU_GTK_ZOOM),show-cursor=on$(QEMU_GTK_EXTRA) -vga std
endif
# x86 pc：默认 -vga std（Bochs/Cirrus 类，PCI 上无 10DE / 无 virtio-gpu）。验证 NVIDIA 驱动探测需真机或自行附加 -device 含 10DE:0300；
# 虚拟 VirtIO 显示为 1af4:1050（virtio-gpu-pci），与本 NVIDIA 路径不同。
QEMU_COMMON_X86 := -machine pc -m $(QEMU_MEM) -serial stdio -no-reboot -no-shutdown \
	$(QEMU_X86_VIDEO_FLAGS) \
	-device virtio-mouse-pci -device virtio-keyboard-pci -device virtio-tablet-pci

# x86_64 UEFI（OVMF）：与仓库根目录 run-iso.sh 一致 — q35、kvm（有 /dev/kvm）否则 tcg、-cpu host/max、smp、双 pflash、ESP 用 virtio-blk。
# 勿在 UEFI 路径复用 QEMU_COMMON_X86 的 -machine pc：OVMF 在 QEMU 上通常与 q35 组合测试；裸 -drive file=esp 在 pc/q35 上总线语义易混。
# 覆盖：QEMU_X86_UEFI_MACHINE、QEMU_X86_UEFI_ACCEL、QEMU_X86_UEFI_CPU、QEMU_SMP_UEFI；关网：QEMU_X86_UEFI_NET=0
QEMU_X86_UEFI_MACHINE ?= q35
ifeq ($(shell test -r /dev/kvm && echo yes),yes)
QEMU_X86_UEFI_ACCEL ?= kvm
QEMU_X86_UEFI_CPU ?= -cpu host
else
QEMU_X86_UEFI_ACCEL ?= tcg
QEMU_X86_UEFI_CPU ?= -cpu max
endif
# Phase3 PML4/串口对照：可设 QEMU_SMP_UEFI=1（单核）排除早期 AP 与 BSP 日志交错；默认 2 与 run-iso 一致。
# Phase3 对照 KVM：即使存在 /dev/kvm，也可强制 `QEMU_X86_UEFI_ACCEL=tcg QEMU_X86_UEFI_CPU=-cpu max` 跑一轮串口（排除虚拟化差异）。
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

# highmem-ecam=off：PCIe ECAM 固定在 0x3f00_0000，与内核 pcie.zig 一致（否则默认 ECAM 可落在 >4GiB）
QEMU_COMMON_AARCH64 := -M virt,highmem-ecam=off -cpu cortex-a72 -m $(QEMU_MEM) -serial stdio \
	-no-reboot -no-shutdown -display gtk,$(QEMU_GTK_ZOOM)$(QEMU_GTK_EXTRA)

QEMU_COMMON_RISCV64 := -M virt -cpu rv64 -m $(QEMU_MEM) -serial stdio \
	-no-reboot -no-shutdown -display gtk,$(QEMU_GTK_ZOOM)$(QEMU_GTK_EXTRA)

# AArch64：默认 **仅 ramfb + virtio-mouse/keyboard（不绑 display）**，GTK 扫 ramfb，避免 “Display output is not active”；ZBM 方向键走全局 VirtIO/USB。
# 设 AARCH64_QEMU_VIRTIO_GPU=1 可附加 virtio-gpu + tablet/keyboard 绑 display（易再现未激活控制台，仅调试固件 GOP）。
# 内核尚无 VirtIO-GPU(1050) 驱动前默认保持 0；里程碑见 docs/cn/DriverMilestones_NT61.md。
# ESP 与 `make build-esp ARCH=aarch64` 一致。
AARCH64_QEMU_VIRTIO_GPU ?= 0
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

# RISC-V64：与 AArch64 相同策略；默认 ramfb 主显示。RISCV64_QEMU_VIRTIO_GPU=1 为 virtio-gpu + 绑 display（易 Display not active）。
# 注意：内核尚无 VirtIO-GPU(1050) 驱动前，勿指望 '=1' 下 GTK 有像素；里程碑见 docs/cn/DriverMilestones_NT61.md。
RISCV64_QEMU_VIRTIO_GPU ?= 0
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

# LoongArch `virt` 公共参数（是否加 -bios / -kernel 由 LOONGARCH64_QEMU_MODE 决定）
# 默认 on：UEFI+ramfb+Aero 下 GTK 主窗口常需固件图形栈参与，否则仍扫 1024×768 GOP、窗口里看不见内核绘制的 ramfb（见 build.conf LOONGARCH64_VIRT_GRAPHICS）。
# 若 virtio-mouse 与抓取异常，可在 build.conf 设 LOONGARCH64_VIRT_GRAPHICS=off 并阅 docs/cn/AeroDesktopRuntime.md。
LOONGARCH64_VIRT_GRAPHICS ?= on
# GTK：show-tabs=on 便于在「固件/ConOut」与 ramfb 等多路 DisplaySurface 间切换（串口已有 first frame 时先看其它标签）。
QEMU_LOONGARCH64_GTK_OPTS ?= $(QEMU_GTK_ZOOM),show-tabs=on
QEMU_LOONGARCH64_BASE := -M virt,graphics=$(LOONGARCH64_VIRT_GRAPHICS) -cpu la464 -m $(QEMU_MEM_LOONGARCH64) -serial stdio \
	-no-reboot -no-shutdown -display gtk,$(QEMU_LOONGARCH64_GTK_OPTS)
# virtio-blk bootindex：便于固件将磁盘列为启动候选（部分环境仍会因 BdsDxe Boot0001 失败而进 Shell）。
# USB 键盘：LoongArch virt 机无默认键鼠，UEFI ConIn 需 usb-kbd 才能接收按键；内核可能无 USB HID 驱动，但不影响 ZBM 菜单。
#
# 显示与虚拟 GPU（LoongArch virt）：
# - 内核 ramfb 路径依赖 fw_cfg「etc/ramfb」→ 必须保留 `-device ramfb`（否则 setupWithDims 失败）。
# - 额外挂 virtio-gpu-pci 后，部分 EDK2 会枚举 VirtIO GOP，有机会 SetMode 到与 build.conf 接近的分辨率，减轻「仅 1024×768 固件 GOP」与 GTK 主窗不同步。
# - GTK 多控制台时若主窗黑屏：菜单 View → 切换 Display / 监视器，或设 LOONGARCH64_QEMU_VIRTIO_GPU=0 仅 ramfb。
#
# 实验矩阵（串口已有 ramfb / first frame 但主窗仍像 UEFI 或全黑时，按序 A/B；详见 docs/cn/AeroDesktopRuntime.md）：
#   1) LOONGARCH64_QEMU_VIRTIO_GPU=0  — 仅 ramfb + REL 键鼠（与 AArch64 默认策略接近），看主窗是否改扫 ramfb。
#   2) 保留 ramfb 的前提下，把 QEMU_LOONGARCH64_BASE 里 -display gtk 改为 -display sdl，或 -vnc :1 + vncviewer。
#   3) Wayland 宿主：GDK_BACKEND=x11 再 make run-loongarch64（或 X11 会话终端）。
# LOONGARCH64_QEMU_VIRTIO_GPU：0=仅 ramfb（默认，GTK 常正确扫 ramfb）；1=ramfb+virtio-gpu-pci；2=仅 virtio-gpu（无 fw_cfg ramfb，实验）
LOONGARCH64_QEMU_VIRTIO_GPU ?= 0
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

# Backward compatibility
QEMU_COMMON := $(QEMU_COMMON_X86)

# ══════════════════════════════════════════════════════
#  Default target: build & run according to build.conf
# ══════════════════════════════════════════════════════

ifeq ($(ZIRCON_NO_LOG),1)
all: run
else
all:
	+@$(MAKE) ZIRCON_NO_LOG=1 all 2>&1 | tee $(LOG_TXT)
endif

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
	@echo "║  ZBM/resolution = $(ZBM_RES_W)x$(ZBM_RES_H)  (sync → build/tmp/kernel_pref_fb_wh.txt + zig 读取)"
	@echo "║  QEMU_MEM     = $(QEMU_MEM)"
	@if [ "$(ARCH)" = "loongarch64" ]; then echo "║  QEMU_MEM_LOONGARCH64 = $(QEMU_MEM_LOONGARCH64)  (run-loongarch64; QEMU virt requires >1G)"; fi
	@echo "║  ENABLE_IDT   = $(ENABLE_IDT)"
	@echo "║  DEBUG_LOG    = $(DEBUG_LOG)"
	@if [ "$(ARCH)" = "x86_64" ]; then \
		echo "║  UEFI QEMU  = $(QEMU_X86_UEFI_MACHINE) accel=$(QEMU_X86_UEFI_ACCEL) smp=$(QEMU_SMP_UEFI) net=$(QEMU_X86_UEFI_NET)  (对齐 run-iso.sh; 关网: QEMU_X86_UEFI_NET=0)"; \
		echo "║  AMD_IGPU   = $(AMD_IGPU)  (false=skip AMD PCI/MMIO probe)"; \
		echo "║  AMD_IGPU_DEFER_PROBE = $(AMD_IGPU_DEFER_PROBE)  (true=probe after GOP resolve)"; \
		echo "║  AMD_KMS_EXPERIMENTAL = $(AMD_KMS_EXPERIMENTAL)"; \
		echo "║  INTEL_IGPU   = $(INTEL_IGPU)  (true=probe Intel 8086 display PCI)"; \
		echo "║  INTEL_IGPU_DEFER_PROBE = $(INTEL_IGPU_DEFER_PROBE)  (true=probe after GOP resolve)"; \
		echo "║  INTEL_KMS_EXPERIMENTAL = $(INTEL_KMS_EXPERIMENTAL)"; \
		echo "║  NVIDIA_GPU   = $(NVIDIA_GPU)  (false=skip NVIDIA 10DE display PCI probe)"; \
		echo "║  NVIDIA_GPU_DEFER_PROBE = $(NVIDIA_GPU_DEFER_PROBE)  (true=probe after GOP resolve)"; \
		echo "║  NVIDIA_KMS_EXPERIMENTAL = $(NVIDIA_KMS_EXPERIMENTAL)"; \
		echo "║  NVIDIA_HDMI_SYNC = $(NVIDIA_HDMI_SYNC)  (true=sync HDMI stub on NVIDIA probe)"; \
		echo "║  DESKTOP_IDLE_SPIN = $(DESKTOP_IDLE_SPIN)  (true=no HLT in desktop loop)"; \
		echo "║  AERO_BLUR_LIGHT = $(AERO_BLUR_LIGHT)  (true=lighter Aero box blur for QEMU)"; \
		echo "║  QEMU_DISPLAY_BACKEND = $(QEMU_DISPLAY_BACKEND)  (x86: gtk|sdl；SDL: make run-qemu-sdl)"; \
		echo "║  QEMU_GTK_ZOOM = $(QEMU_GTK_ZOOM)  (默认 1:1；缩放: make run-qemu-zoom-fit)"; \
	fi
	@echo "║  FIRMWARE_DIR = $(FIRMWARE_DIR)"
	@if [ "$(ARCH)" = "loongarch64" ]; then \
		echo "║  LOONGARCH64_FIRMWARE_DIR = $(LOONGARCH64_FIRMWARE_DIR)"; \
		echo "║  LOONGARCH64_EFI_CODE     = $(LOONGARCH64_EFI_CODE)"; \
		echo "║  LOONGARCH64_BOOT_EFI     = $(LOONGARCH64_BOOT_EFI)"; \
		echo "║  LOONGARCH64_QEMU_MODE     = $(LOONGARCH64_QEMU_MODE)  (kernel|uefi; ZBM+UEFI only)"; \
		echo "║  LOONGARCH64_QEMU_VIRTIO_GPU = $(LOONGARCH64_QEMU_VIRTIO_GPU)  (0=仅 ramfb 默认, 1=ramfb+virtio-gpu, 2=仅 virtio-gpu)"; \
		echo "║  LOONGARCH64_VIRT_GRAPHICS   = $(LOONGARCH64_VIRT_GRAPHICS)  (Makefile 默认 on，利 GTK 与固件图形栈；可设 off)"; \
		echo "║  QEMU_LOONGARCH64_GTK_OPTS   = $(QEMU_LOONGARCH64_GTK_OPTS)  (gtk 子选项；置空可关 show-tabs)"; \
		echo "║  LOONGSON_IGPU = $(LOONGSON_IGPU)  (false=skip 0014 display PCI probe)"; \
		echo "║  LOONGSON_IGPU_DEFER_PROBE = $(LOONGSON_IGPU_DEFER_PROBE)"; \
		echo "║  LOONGSON_KMS_EXPERIMENTAL = $(LOONGSON_KMS_EXPERIMENTAL)"; \
	fi
	@if [ "$(ARCH)" = "aarch64" ]; then \
		echo "║  AARCH64_QEMU_VIRTIO_GPU = $(AARCH64_QEMU_VIRTIO_GPU)  (0=ramfb+REL 默认, 1=virtio-gpu 绑 display)"; \
	fi
	@if [ "$(ARCH)" = "riscv64" ]; then \
		echo "║  RISCV64_QEMU_VIRTIO_GPU = $(RISCV64_QEMU_VIRTIO_GPU)  (0=ramfb+REL 默认, 1=virtio-gpu 绑 display)"; \
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

# RESOLUTION：默认由脚本读 build.conf；仅命令行/环境 RESOLUTION= 时覆盖；生成 build/tmp/zircon_pref_fb.h + kernel_pref_fb_wh.txt
sync-resolution:
	@mkdir -p $(TMP_DIR)
	@$(SYNC_RESOLUTION_CMD)

fetch-assets:
	@bash $(ROOT_DIR)/scripts/fetch-assets.sh

# ══════════════════════════════════════════════════════
#  help
# ══════════════════════════════════════════════════════

help:
	@echo "ZirconOSAero v$(VERSION) — NT 6.1 (Windows 7) style, ZBM-only boot"
	@echo ""
	@echo "Configuration (edit build.conf or override via CLI):"
	@echo "  make show-config            Show current build.conf settings"
	@echo "  make sync-resolution        RESOLUTION → configs + build/tmp/zircon_pref_fb.h (C stub / 嵌入 desktop)"
	@echo "  make configure              Interactive configuration wizard"
	@echo ""
	@echo "Build:"
	@echo "  make                        Build & run (using build.conf)"
	@echo "  make build                  Build kernel only"
	@echo "  make build-release          Build kernel (ReleaseSafe)"
	@echo "  make build-desktop          Build desktop theme (EXE + LIB + DLL)"
	@echo "  make build-desktop-all      Build all desktop themes"
	@echo "  make build-desktop-dll      Build desktop theme DLL only"
	@echo "  make iso / iso-debug        UEFI ISO (Debug + -Ddebug=true): 串口与屏幕均显示 klog → zirconos-$(VERSION)-uefi-x86_64-debug.iso"
	@echo "  make iso-release            UEFI ISO (ReleaseSafe + -Ddebug=false): 屏幕不刷文本日志 → …-release.iso（后续可接 logo 动画）"
	@echo "  make build-zbm-uefi        Build ZBM UEFI application"
	@echo "  make build-zbm-bios        Build ZBM BIOS components"
	@echo "  make build-zbm-disk        Build ZBM bootable disk images"
	@echo "  make build-esp             Build EFI System Partition image (dosfstools mkfs.vfat + mtools: mmd, mcopy, mdir; see docs/REPRODUCE_BUILD.md)"
	@echo ""
	@echo "Run (auto-selects from build.conf):"
	@echo "  make run                    Build + run per build.conf"
	@echo "  make run-qemu-1to1          Explicit 1:1 pixels (same as default run; QEMU_GTK_ZOOM=zoom-to-fit=off)"
	@echo "  make run-qemu-zoom-fit      Scale guest FB into window (QEMU_GTK_ZOOM=zoom-to-fit=on)"
	@echo "  make run-qemu-sdl           x86: run with -display sdl (experimental; compare window scaling vs GTK)"
	@echo "  make run-fb-large           RESOLUTION=2560x1440x32 + AERO_BLUR_LIGHT=true（高分 + 轻模糊）"
	@echo "  make run-debug              Run with GDB server on :1234"
	@echo "  make run-aarch64            UEFI boot on QEMU AArch64 (EDK2 nightly; 默认 ramfb+REL 键鼠)"
	@echo "  make run-riscv64            UEFI boot on QEMU RISC-V64 virt (VIRT.fd + ESP; 默认 ramfb+REL)"
	@echo "  make run-loongarch64        QEMU LoongArch64（默认: UEFI+ESP+startup.nsh → ZBM 菜单）"
	@echo "  make run-loongarch64-autozbm  同 run（LOONGARCH64_QEMU_MODE=uefi 别名）"
	@echo "  make run-aarch64-debug      AArch64 + GDB on :1234"
	@echo "  make run-riscv64-debug      RISC-V64 UEFI + GDB on :1234"
	@echo "  make run-loongarch64-debug  LoongArch64 + GDB on :1234"
	@echo "  make run-loongarch64-serial-debug  同 run-loongarch64，串口 tee 到终端 + .cursor/debug-80cc1c.log"
	@echo ""
	@echo "Override examples:"
	@echo "  make DESKTOP=aero                        Aero desktop (default)"
	@echo "  make BOOT_METHOD=mbr BOOTLOADER=zbm      BIOS/MBR + ZBM (raw disk)"
	@echo "  make BOOT_METHOD=uefi BOOTLOADER=zbm     UEFI + ZBM (ESP)：QEMU 为 q35+OVMF pflash+virtio-blk ESP，与 run-iso.sh 固件方式一致"
	@echo "  make DESKTOP=none                        Text/CMD mode"
	@echo "  make AMD_IGPU=false MOUSE_DEBUG=true     对照指针：排除 AMD 探测 + VirtIO 串口跟踪"
	@echo "  make INTEL_IGPU=false                    x86：关闭 Intel 8086 显示 PCI 探测（默认与 AMD 并存，解析链 Intel 先于 AMD）"
	@echo "  make NVIDIA_GPU=false                    x86：关闭 NVIDIA 10DE 显示 PCI 探测（解析链：龙芯→NVIDIA→Intel→AMD）"
	@echo "  make DESKTOP_IDLE_SPIN=true              桌面循环不 HLT（调试 IRQ/鼠标）"
	@echo "  make AERO_BLUR_LIGHT=true                内核 Aero 盒式模糊默认半径/遍数下调（zig -Daero_blur_light）"
	@echo "  make run-qemu-zoom-fit                     GTK 缩放客体画面以适配窗口（默认 run 为 1:1）"
	@echo "  make QEMU_GTK_ZOOM=zoom-to-fit=on run      同上：显式缩放模式"
	@echo "  make run-aarch64 AARCH64_QEMU_VIRTIO_GPU=1 / run-riscv64 RISCV64_QEMU_VIRTIO_GPU=1  附加 virtio-gpu（易 Display not active）"
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
	@echo "  make fetch-assets           Generate missing Aero wallpaper PNG placeholders (see scripts/fetch-assets.sh)"
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

build: sync-resolution
	@mkdir -p $(TMP_DIR)
	@echo "[ZirconOSAero] Building kernel (arch=$(ARCH), optimize=$(OPTIMIZE), desktop=$(DESKTOP))..."
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
		-Dnvidia_gpu=$(NVIDIA_GPU) \
		-Dnvidia_gpu_defer_probe=$(NVIDIA_GPU_DEFER_PROBE) \
		-Dnvidia_kms_experimental=$(NVIDIA_KMS_EXPERIMENTAL) \
		-Dnvidia_hdmi_sync=$(NVIDIA_HDMI_SYNC) \
		-Dloongson_igpu=$(LOONGSON_IGPU) \
		-Dloongson_igpu_defer_probe=$(LOONGSON_IGPU_DEFER_PROBE) \
		-Dloongson_kms_experimental=$(LOONGSON_KMS_EXPERIMENTAL) \
		-Ddesktop_idle_spin=$(DESKTOP_IDLE_SPIN) \
		-Ddesktop_bisect=$(DESKTOP_BISECT) \
		-Daero_blur_light=$(AERO_BLUR_LIGHT) \
		-Ddefault_desktop=$(DESKTOP) \
		--cache-dir $(TMP_DIR)/zig-cache \
		--prefix $(TMP_DIR)/kernel-prefix
	@echo "[ZirconOSAero] Stripping debug sections..."
ifeq ($(ARCH),loongarch64)
	@cp -f $(KERNEL_ELF_DEBUG) $(KERNEL_ELF)
	@echo "[ZirconOSAero] (loongarch64: copied ELF; --strip-debug skipped: host objcopy/zig objcopy lack full support)"
else
	@objcopy --strip-debug $(KERNEL_ELF_DEBUG) $(KERNEL_ELF) 2>/dev/null || \
		cp -f $(KERNEL_ELF_DEBUG) $(KERNEL_ELF)
endif
	@echo "[ZirconOSAero] Kernel: $(KERNEL_ELF)"

build-release:
	@$(MAKE) build OPTIMIZE=ReleaseSafe

# ══════════════════════════════════════════════════════
#  Build desktop theme
# ══════════════════════════════════════════════════════

build-desktop:
	@echo "[ZirconOSAero] Building desktop theme: $(DESKTOP) (EXE + LIB + DLL)..."
	@if [ "$(DESKTOP)" = "none" ]; then \
		echo "[ZirconOSAero] DESKTOP=none, skipping desktop build"; \
	elif [ -d "$(THEME_DIR)" ]; then \
		cd $(THEME_DIR) && zig build -Doptimize=$(OPTIMIZE) && \
		cd $(THEME_DIR) && zig build dll -Doptimize=$(OPTIMIZE); \
	else \
		echo "[ZirconOSAero] Theme directory not found: $(THEME_DIR)"; \
	fi

build-desktop-all:
	@echo "[ZirconOSAero] Building all desktop themes (EXE + LIB + DLL)..."
	@for theme in aero; do \
		dir="$(ROOT_DIR)/src/desktop/$$theme"; \
		if [ -d "$$dir" ]; then \
			echo "[ZirconOSAero]   Building $$theme..."; \
			cd "$$dir" && zig build -Doptimize=$(OPTIMIZE) && \
			cd "$$dir" && zig build dll -Doptimize=$(OPTIMIZE); \
		else \
			echo "[ZirconOSAero]   Skipping $$theme (not found: $$dir)"; \
		fi; \
	done

build-desktop-dll:
	@echo "[ZirconOSAero] Building desktop theme DLL: $(DESKTOP)..."
	@if [ "$(DESKTOP)" = "none" ]; then \
		echo "[ZirconOSAero] DESKTOP=none, skipping DLL build"; \
	elif [ -d "$(THEME_DIR)" ]; then \
		cd $(THEME_DIR) && zig build dll -Doptimize=$(OPTIMIZE); \
	else \
		echo "[ZirconOSAero] Theme directory not found: $(THEME_DIR)"; \
	fi

# ══════════════════════════════════════════════════════
#  ZBM UEFI Boot Application
# ══════════════════════════════════════════════════════

build-zbm-uefi: sync-resolution
ifeq ($(ARCH),loongarch64)
	@$(MAKE) build-zbm-loongarch-uefi
else ifeq ($(ARCH),riscv64)
	@$(MAKE) build-zbm-riscv64-uefi
else
	@echo "[ZirconOSAero] Building ZBM UEFI boot application..."
	@mkdir -p $(UEFI_PREFIX) $(UEFI_CACHE) $(TMP_DIR)
	cd $(ROOT_DIR) && zig build uefi \
		-Doptimize=$(OPTIMIZE) \
		-Darch=$(ARCH) \
		-Ddesktop=$(DESKTOP) \
		-Ddebug=$(DEBUG_LOG) \
		--cache-dir $(UEFI_CACHE) \
		--prefix $(UEFI_PREFIX)
	@echo "[ZirconOSAero] UEFI app: $(UEFI_EFI)"
endif

# LoongArch UEFI：默认 C stub（稳定）；Zig stub 有 INE 异常，LOONGARCH64_USE_C_STUB=0 时用 Zig
LOONGARCH64_USE_C_STUB ?= 1

# Zig stub：main_loongarch64.zig + linker_stub.lds（与 C stub 同流程），固件可加载
build-zbm-loongarch64-stub:
	@echo "[ZirconOSAero] LoongArch UEFI: Building Zig ZBM stub (AevOS-style)..."
	@mkdir -p $(TMP_DIR)
	@$(MAKE) build ARCH=loongarch64
	@bash $(ROOT_DIR)/scripts/build/build-zbm-loongarch64-stub.sh "$(ZBM_LOONGARCH64_EFI)"

# C stub：无 gnu-efi，与 AevOS 相同构建流程，QEMU_EFI.fd 可加载
build-stub-loongarch64:
	@echo "[ZirconOSAero] LoongArch UEFI: Building C stub (AevOS-style)..."
	@mkdir -p $(TMP_DIR)
	@test -f "$(TMP_DIR)/zircon_pref_fb.h" || $(MAKE) sync-resolution
	@test -f "$(TMP_DIR)/zircon_pref_fb.h" || { echo "[ZirconOSAero] ERROR: missing $(TMP_DIR)/zircon_pref_fb.h — run: make sync-resolution 或 make build" >&2; exit 1; }
	@bash $(ROOT_DIR)/scripts/build/build-stub-loongarch64.sh "$(ZBM_LOONGARCH64_EFI)"

# Zig ZBM：GNU-EFI 链接，部分 QEMU_EFI.fd 报 Unsupported
# 依赖 sync-resolution：保证 zircon_pref_fb.h / 嵌入分辨率与 build.conf 一致（直接 make 本目标时也会先 sync）
build-zbm-loongarch-uefi: sync-resolution
	@echo "[ZirconOSAero] LoongArch ZBM UEFI: GNU-EFI link $(ZBM_LOONGARCH64_O) → $(ZBM_LOONGARCH64_EFI)"
	@test -f "$(ZBM_LOONGARCH64_O)" || { echo "[ZirconOSAero] ERROR: missing $(ZBM_LOONGARCH64_O). Run: make build ARCH=loongarch64" >&2; exit 1; }
	@if [ ! -f "$(ROOT_DIR)/gnu-efi/loongarch64-built/crt0-efi-loongarch64.o" ]; then \
		echo "[ZirconOSAero] 首次需要 GNU-EFI（LoongArch），正在执行 fetch-gnu-efi …"; \
		$(MAKE) fetch-gnu-efi; \
	fi
	@bash $(ROOT_DIR)/scripts/build/zbm-loongarch64-efi.sh "$(ZBM_LOONGARCH64_O)" "$(ZBM_LOONGARCH64_EFI)"

# RISC-V64：Zig 仅生成 .o，GNU-EFI（ncroxon）链接为 BOOTRISCV64.EFI
build-zbm-riscv64-uefi:
	@echo "[ZirconOSAero] RISC-V64 ZBM: GNU-EFI link $(ZBM_RISCV64_O) → $(ZBM_RISCV64_EFI)"
	@test -f "$(ZBM_RISCV64_O)" || { echo "[ZirconOSAero] ERROR: missing $(ZBM_RISCV64_O). Run: make build ARCH=riscv64" >&2; exit 1; }
	@if [ ! -f "$(ROOT_DIR)/gnu-efi/riscv64-built/crt0-efi-riscv64.o" ]; then \
		echo "[ZirconOSAero] 首次需要 GNU-EFI（RISC-V），执行 fetch-gnu-efi-riscv64 …"; \
		bash $(ROOT_DIR)/scripts/build/fetch-gnu-efi-riscv64.sh || exit 1; \
	fi
	@bash $(ROOT_DIR)/scripts/build/zbm-riscv64-efi.sh "$(ZBM_RISCV64_O)" "$(ZBM_RISCV64_EFI)"

# ══════════════════════════════════════════════════════
#  ZBM BIOS Boot Components (MBR + VBR + Stage2)
# ══════════════════════════════════════════════════════

build-zbm-bios:
	@echo "[ZirconOSAero] Building ZBM BIOS components..."
	@mkdir -p $(ZBM_DIR)
	as --32 -o $(ZBM_DIR)/mbr.o $(ZBM_SRC_DIR)/mbr.s
	ld -m elf_i386 -T $(ROOT_DIR)/link/mbr.ld -o $(ZBM_DIR)/mbr.bin $(ZBM_DIR)/mbr.o
	truncate -s 512 $(ZBM_DIR)/mbr.bin
	@echo "[ZirconOSAero] MBR: $(ZBM_DIR)/mbr.bin"
	as --32 -o $(ZBM_DIR)/vbr.o $(ZBM_SRC_DIR)/vbr.s
	ld -m elf_i386 -T $(ROOT_DIR)/link/vbr.ld -o $(ZBM_DIR)/vbr.bin $(ZBM_DIR)/vbr.o
	truncate -s 512 $(ZBM_DIR)/vbr.bin
	@echo "[ZirconOSAero] VBR: $(ZBM_DIR)/vbr.bin"
	as --32 -o $(ZBM_DIR)/stage2.o $(ZBM_SRC_DIR)/stage2.s
	ld -m elf_i386 -T $(ROOT_DIR)/link/zbm_bios.ld -o $(ZBM_DIR)/stage2.elf $(ZBM_DIR)/stage2.o
	objcopy -O binary $(ZBM_DIR)/stage2.elf $(ZBM_DIR)/stage2.bin
	@STAGE2_SZ=$$(stat -c%s "$(ZBM_DIR)/stage2.bin"); \
	if [ "$$STAGE2_SZ" -gt 32768 ]; then \
		echo "[ZirconOSAero] ERROR: stage2.bin is $$STAGE2_SZ bytes; max 32768 (64 sectors before kernel at seek 2113)" >&2; \
		exit 1; \
	fi; \
	echo "[ZirconOSAero] Stage2: $(ZBM_DIR)/stage2.bin ($$STAGE2_SZ bytes)"
	cd $(ROOT_DIR) && zig build zbm \
		-Doptimize=ReleaseSmall \
		-Darch=x86_64 \
		--cache-dir $(TMP_DIR)/zig-cache \
		--prefix $(TMP_DIR)/kernel-prefix
	@echo "[ZirconOSAero] ZBM BIOS components built"

# ══════════════════════════════════════════════════════
#  ZBM Disk Images (MBR + GPT)
# ══════════════════════════════════════════════════════

build-zbm-disk: build-zbm-bios build
	@echo "[ZirconOSAero] Building ZBM disk images (128 MB)..."
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
	@K_SZ=$$(stat -c%s "$(KERNEL_ELF)"); \
	MAX_K=$$(( (128*1024*1024/512 - 2113) * 512 )); \
	if [ "$$K_SZ" -gt "$$MAX_K" ]; then \
		echo "[ZirconOSAero] ERROR: kernel.elf ($$K_SZ bytes) exceeds MBR disk budget ($$MAX_K bytes from sector 2113 to end of 128MiB image)" >&2; \
		exit 1; \
	fi
	dd if=$(KERNEL_ELF) of=$(ZBM_DISK_MBR) bs=512 seek=2113 conv=notrunc status=none
	@echo "[ZirconOSAero] MBR disk: $(ZBM_DISK_MBR)"
	@if command -v sgdisk >/dev/null 2>&1; then \
		dd if=/dev/zero of=$(ZBM_DISK_GPT) bs=1M count=128 status=none; \
		sgdisk --clear $(ZBM_DISK_GPT) >/dev/null 2>&1; \
		sgdisk -n 1:2048:67583 -t 1:EF00 -c 1:"EFI System" $(ZBM_DISK_GPT) >/dev/null 2>&1; \
		sgdisk -n 2:67584:0 -t 2:8300 -c 2:"ZirconOSAero System" $(ZBM_DISK_GPT) >/dev/null 2>&1; \
		dd if=$(ZBM_DIR)/stage2.bin of=$(ZBM_DISK_GPT) bs=512 seek=34 conv=notrunc status=none; \
		echo "[ZirconOSAero] GPT disk: $(ZBM_DISK_GPT)"; \
	else \
		echo "[ZirconOSAero] sgdisk not found, skipping GPT (apt install gdisk)"; \
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
	@echo "[ZirconOSAero] Building ESP image (arch=$(ARCH))..."
ifeq ($(ARCH),loongarch64)
	@ZIRCON_BUILD_TMP="$(TMP_DIR)" BOOTLOADER=$(BOOTLOADER) \
		ZBM_LOONGARCH64_EFI="$(ZBM_LOONGARCH64_EFI)" \
		bash $(ROOT_DIR)/scripts/build/mkesp-loongarch64.sh "$(ESP_IMG)" "$(KERNEL_ELF)" "$(ZBM_LOONGARCH64_EFI)"
else
	@set -e; \
	test -f "$(KERNEL_ELF)" || { echo "[ZirconOSAero] ERROR: missing $(KERNEL_ELF). Run: make build" >&2; exit 1; }; \
	command -v mkfs.vfat >/dev/null 2>&1 || { echo "[ZirconOSAero] ERROR: mkfs.vfat not found (dosfstools). e.g. apt install dosfstools" >&2; exit 1; }; \
	dd if=/dev/zero of=$(ESP_IMG) bs=1M count=$(ESP_IMG_MB) status=none; \
	mkfs.vfat -F 32 $(ESP_IMG) >/dev/null; \
	mmd -i $(ESP_IMG) ::/EFI; \
	mmd -i $(ESP_IMG) ::/EFI/BOOT; \
	case "$(ARCH)" in \
	aarch64)  mcopy -i $(ESP_IMG) $(UEFI_EFI) ::/EFI/BOOT/BOOTAA64.EFI ;; \
	riscv64)  mcopy -i $(ESP_IMG) $(UEFI_EFI) ::/EFI/BOOT/BOOTRISCV64.EFI ;; \
	*)        mcopy -i $(ESP_IMG) $(UEFI_EFI) ::/EFI/BOOT/BOOTX64.EFI ;; \
	esac; \
	mmd -i $(ESP_IMG) ::/boot || { echo "[ZirconOSAero] ERROR: mmd ::/boot failed (mtools / FAT on $(ESP_IMG))." >&2; exit 1; }; \
	mcopy -i $(ESP_IMG) $(KERNEL_ELF) ::/boot/kernel.elf || { echo "[ZirconOSAero] ERROR: mcopy kernel.elf failed. Need mtools: apt install mtools (or distro equivalent)." >&2; exit 1; }; \
	mdir -i $(ESP_IMG) ::/boot | grep -Eq 'kernel[[:space:]]+elf' || { echo "[ZirconOSAero] ERROR: kernel.elf not listed on ESP under ::/boot (mdir lists 8.3-style name)." >&2; exit 1; }
endif
	@echo "[ZirconOSAero] ESP image: $(ESP_IMG)  (self-check: mdir -i $(ESP_IMG) ::/boot)"

# ══════════════════════════════════════════════════════
#  ISO (UEFI only — embedded FAT ESP + xorriso)
#  iso-debug：内核/ ZBM -Ddebug=true → klog 走串口 + 帧缓冲/VGA（屏幕可见日志）
#  iso-release：ReleaseSafe + -Ddebug=false → 屏幕不输出 klog 文本（串口仍为 ERR 及以上）；便于后续全屏 logo
#  VirtualBox：系统 → 主板 → 勾选「启用 EFI」；存储 → 光驱挂载本 ISO。
# ══════════════════════════════════════════════════════

iso: iso-debug

iso-debug:
ifneq ($(ARCH),x86_64)
	$(error iso-debug is for ARCH=x86_64 only; use build-esp + QEMU for $(ARCH))
endif
	@command -v xorriso >/dev/null 2>&1 || { echo "[ZirconOSAero] xorriso required (e.g. apt install xorriso)" >&2; exit 1; }
	@echo "[ZirconOSAero] UEFI ISO (DEBUG) — arch=$(ARCH) desktop=$(DESKTOP) → $(notdir $(ISO_DEBUG))"
	@$(MAKE) build OPTIMIZE=Debug DEBUG_LOG=true
	@$(MAKE) build-zbm-uefi OPTIMIZE=Debug DEBUG_LOG=true DESKTOP=$(DESKTOP)
	@test -f "$(UEFI_EFI)" || { echo "[ZirconOSAero] missing $(UEFI_EFI) (zig build uefi failed?)" >&2; exit 1; }
	@mkdir -p $(RELEASE_DIR)
	bash $(ROOT_DIR)/scripts/build/mkiso-uefi-zbm.sh "$(ISO_DEBUG)" "$(KERNEL_ELF)" "$(UEFI_EFI)" "$(ARCH)" "$(VERSION)" "debug"
	@echo "[ZirconOSAero] ISO (debug): $(ISO_DEBUG)"
	@echo "[ZirconOSAero] VirtualBox: enable EFI; attach this ISO as optical drive."

iso-release:
ifneq ($(ARCH),x86_64)
	$(error iso-release is for ARCH=x86_64 only; use build-esp + QEMU for $(ARCH))
endif
	@command -v xorriso >/dev/null 2>&1 || { echo "[ZirconOSAero] xorriso required (e.g. apt install xorriso)" >&2; exit 1; }
	@echo "[ZirconOSAero] UEFI ISO (RELEASE) — arch=$(ARCH) desktop=$(DESKTOP) → $(notdir $(ISO_RELEASE))"
	@$(MAKE) build OPTIMIZE=ReleaseSafe DEBUG_LOG=false
	@$(MAKE) build-zbm-uefi OPTIMIZE=ReleaseSafe DEBUG_LOG=false DESKTOP=$(DESKTOP)
	@test -f "$(UEFI_EFI)" || { echo "[ZirconOSAero] missing $(UEFI_EFI) (zig build uefi failed?)" >&2; exit 1; }
	@mkdir -p $(RELEASE_DIR)
	bash $(ROOT_DIR)/scripts/build/mkiso-uefi-zbm.sh "$(ISO_RELEASE)" "$(KERNEL_ELF)" "$(UEFI_EFI)" "$(ARCH)" "$(VERSION)" "release"
	@echo "[ZirconOSAero] ISO (release): $(ISO_RELEASE)"
	@echo "[ZirconOSAero] VirtualBox: enable EFI; attach this ISO as optical drive."

# ══════════════════════════════════════════════════════
#  run: unified entry point driven by build.conf
# ══════════════════════════════════════════════════════

# 2.5K 帧缓冲 + 默认收紧 Aero 模糊（仍可能 CPU 瓶颈；可调 `nt61_aero_defaults`）
run-fb-large:
	@$(MAKE) run RESOLUTION=2560x1440x32 AERO_BLUR_LIGHT=true

# GTK: explicit 1:1 (same as default QEMU_GTK_ZOOM).
run-qemu-1to1:
	@$(MAKE) run QEMU_GTK_ZOOM=zoom-to-fit=off

# GTK: scale guest framebuffer to fit QEMU window (old default behavior).
run-qemu-zoom-fit:
	@$(MAKE) run QEMU_GTK_ZOOM=zoom-to-fit=on

run-qemu-sdl:
	@$(MAKE) run QEMU_DISPLAY_BACKEND=sdl

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
	@echo "[ZirconOSAero] BIOS + ZBM → $(DESKTOP) Desktop ($(QEMU_MEM))..."
	qemu-system-x86_64 \
		-drive format=raw,file=$(ZBM_DISK_MBR) \
		$(QEMU_COMMON)

# ── ZBM + UEFI ──
_run-zbm-uefi: build-esp
	@echo "[ZirconOSAero] UEFI + ZBM ($(QEMU_X86_UEFI_MACHINE)+OVMF, virtio ESP) → $(DESKTOP) ($(QEMU_MEM))..."
	@mkdir -p $(TMP_DIR)
	@cp -f $(OVMF_VARS) $(TMP_DIR)/OVMF_VARS.fd
	qemu-system-x86_64 \
		-drive if=pflash,format=raw,readonly=on,file=$(OVMF_CODE) \
		-drive if=pflash,format=raw,file=$(TMP_DIR)/OVMF_VARS.fd \
		-drive if=none,id=zircon-esp0,file=$(ESP_IMG),format=raw \
		-device virtio-blk-pci,drive=zircon-esp0,bootindex=0 \
		$(QEMU_COMMON_X86_UEFI)

# ── Debug mode (GDB) — ZBM MBR disk (same kernel path as build-zbm-disk) ──
ifeq ($(ZIRCON_NO_LOG),1)
run-debug: build-zbm-disk
	@echo "[ZirconOSAero] Debug mode (GDB on :1234), ZBM MBR disk..."
	qemu-system-x86_64 \
		-drive format=raw,file=$(ZBM_DISK_MBR) \
		$(QEMU_COMMON) \
		-s -S
else
run-debug:
	+@$(MAKE) ZIRCON_NO_LOG=1 run-debug 2>&1 | tee $(LOG_TXT)
endif

# ══════════════════════════════════════════════════════
#  AArch64 boot (EDK2 nightly firmware)
# ══════════════════════════════════════════════════════

run-aarch64:
	@$(MAKE) build-esp ARCH=aarch64
	@echo "[ZirconOSAero] AArch64 UEFI boot (EDK2 nightly firmware)..."
	@if [ ! -f "$(AARCH64_EFI_CODE)" ]; then \
		echo "[ZirconOSAero] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	@mkdir -p $(TMP_DIR)
	@echo "[ZirconOSAero] Padding AArch64 pflash to $(AARCH64_PFLASH_MB)MiB (QEMU virt requirement)..."
	@dd if=/dev/zero of=$(TMP_DIR)/AARCH64_PFLASH0.fd bs=1M count=$(AARCH64_PFLASH_MB) status=none
	@dd if=$(AARCH64_EFI_CODE) of=$(TMP_DIR)/AARCH64_PFLASH0.fd conv=notrunc status=none
	@dd if=/dev/zero of=$(TMP_DIR)/AARCH64_PFLASH1.fd bs=1M count=$(AARCH64_PFLASH_MB) status=none
	@dd if=$(AARCH64_EFI_VARS) of=$(TMP_DIR)/AARCH64_PFLASH1.fd conv=notrunc status=none
	qemu-system-aarch64 \
		$(QEMU_COMMON_AARCH64) \
		-drive if=pflash,format=raw,readonly=on,file=$(TMP_DIR)/AARCH64_PFLASH0.fd \
		-drive if=pflash,format=raw,file=$(TMP_DIR)/AARCH64_PFLASH1.fd \
		$(QEMU_AARCH64_DEVICES)

run-aarch64-debug:
	@$(MAKE) build-esp ARCH=aarch64
	@echo "[ZirconOSAero] AArch64 debug mode (GDB on :1234)..."
	@if [ ! -f "$(AARCH64_EFI_CODE)" ]; then \
		echo "[ZirconOSAero] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	@mkdir -p $(TMP_DIR)
	@echo "[ZirconOSAero] Padding AArch64 pflash to $(AARCH64_PFLASH_MB)MiB (QEMU virt requirement)..."
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

run-riscv64:
	@$(MAKE) build-esp ARCH=riscv64
	@echo "[ZirconOSAero] RISC-V64 UEFI boot ($(RISCV64_EFI_CODE))..."
	@if [ ! -f "$(RISCV64_EFI_CODE)" ]; then \
		echo "[ZirconOSAero] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	qemu-system-riscv64 \
		$(QEMU_COMMON_RISCV64) \
		-bios $(RISCV64_EFI_CODE) \
		-drive if=none,id=zircon-esp0,file=$(ESP_IMG_RISCV64),format=raw \
		-device virtio-blk-pci,drive=zircon-esp0,bootindex=0 \
		$(QEMU_RISCV64_EXTRA)

run-riscv64-debug:
	@$(MAKE) build-esp ARCH=riscv64
	@echo "[ZirconOSAero] RISC-V64 UEFI debug (GDB on :1234)..."
	@if [ ! -f "$(RISCV64_EFI_CODE)" ]; then \
		echo "[ZirconOSAero] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	qemu-system-riscv64 \
		$(QEMU_COMMON_RISCV64) \
		-bios $(RISCV64_EFI_CODE) \
		-drive if=none,id=zircon-esp0,file=$(ESP_IMG_RISCV64),format=raw \
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
	@echo "[ZirconOSAero] LoongArch64 QEMU: -kernel $(KERNEL_ELF) + ramfb（Aero 桌面）"
	@echo "[ZirconOSAero] 若 QEMU 持续显示 'Guest has not initialized the display'，可尝试: make run-loongarch64 LOONGARCH64_QEMU_MODE=uefi（需固件）"
	qemu-system-loongarch64 $(QEMU_LOONGARCH64_BASE) \
		-kernel $(KERNEL_ELF) \
		-device ramfb,id=zircon_ramfb
else ifeq ($(LOONGARCH64_QEMU_MODE),uefi)
	@$(MAKE) build-esp ARCH=loongarch64 DESKTOP=$(DESKTOP)
	@echo "[ZirconOSAero] LoongArch64 UEFI + ZBM — $(LOONGARCH64_EFI_CODE)"
	@if [ ! -f "$(LOONGARCH64_EFI_CODE)" ]; then \
		echo "[ZirconOSAero] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	@echo "[ZirconOSAero] 等待内置 Shell 的 startup.nsh 倒计时结束（勿按 ESC）后将进入 ZBM 菜单；串口与 QEMU 窗口均可查看 ConOut。"
	@echo "[ZirconOSAero] 键盘操作：请先点击 QEMU 窗口使其获得焦点，再用方向键/数字键选择启动项。"
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

# 串口同时显示在终端并写入 .cursor/debug-80cc1c.log（勿用裸 `| python3`，否则终端无输出）
run-loongarch64-serial-debug:
	@bash $(CURDIR)/scripts/run_loongarch64_with_serial_debug_log.sh

run-loongarch64-debug:
ifeq ($(LOONGARCH64_QEMU_MODE),kernel)
	@$(MAKE) build ARCH=loongarch64
	@echo "[ZirconOSAero] LoongArch64 debug: -kernel + ramfb + GDB :1234"
	qemu-system-loongarch64 $(QEMU_LOONGARCH64_BASE) \
		-kernel $(KERNEL_ELF) -device ramfb,id=zircon_ramfb -s -S
else ifeq ($(LOONGARCH64_QEMU_MODE),uefi)
	@$(MAKE) build-esp ARCH=loongarch64 DESKTOP=$(DESKTOP)
	@echo "[ZirconOSAero] LoongArch64 UEFI debug (GDB on :1234)..."
	@if [ ! -f "$(LOONGARCH64_EFI_CODE)" ]; then \
		echo "[ZirconOSAero] Firmware not found. Run: make fetch-firmware"; \
		exit 1; \
	fi
	@echo "[ZirconOSAero] 若需手动：fs0: → cd \\EFI\\BOOT → BOOTLOONGARCH64.EFI"
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
		echo "[ZirconOSAero] $(ROOT_DIR)/scripts/fonts/fetch-fonts.sh not found"; \
	fi

resources:
	@echo "[ZirconOSAero] Resources for $(DESKTOP) theme:"
	@if [ -n "$(THEME_DIR)" ] && [ -d "$(THEME_DIR)/resources" ]; then \
		echo "  Wallpapers:"; \
		find $(THEME_DIR)/resources/wallpapers -name '*.png' 2>/dev/null | sed 's/.*\//    /' | sort || echo "    (none)"; \
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
	@echo "[ZirconOSAero] 桌面主题与资源: src/desktop/<主题>/resources/，共享字体: src/fonts/"

# GNU-EFI（LoongArch ZBM 链接所需 crt0/lds → gnu-efi/loongarch64-built/）
fetch-gnu-efi:
	@echo "[ZirconOSAero] Fetching GNU-EFI (for LoongArch BOOTLOONGARCH64.EFI link)..."
	@bash $(ROOT_DIR)/scripts/build/fetch-gnu-efi.sh "$(ROOT_DIR)/gnu-efi/loongarch64-built"

fetch-gnu-efi-riscv64:
	@echo "[ZirconOSAero] Fetching GNU-EFI (ncroxon, RISC-V64 BOOTRISCV64.EFI link)..."
	@bash $(ROOT_DIR)/scripts/build/fetch-gnu-efi-riscv64.sh "$(ROOT_DIR)/gnu-efi/riscv64-built"

# ── Firmware (EDK2 nightly from https://retrage.github.io/edk2-nightly/) ──
fetch-firmware:
	@echo "[ZirconOSAero] Downloading EDK2 nightly firmware..."
	@bash $(ROOT_DIR)/scripts/build/fetch-firmware.sh $(FIRMWARE_DIR)

# LoongArch 默认可移动介质引导名 \EFI\BOOT\BOOTLOONGARCH64.EFI（无则固件直接进 Shell）
fetch-loongarch-boot-efi:
	@echo "[ZirconOSAero] Downloading BOOTLOONGARCH64.EFI (EDK2 RELEASE Shell → standard boot path)..."
	@mkdir -p $(FIRMWARE_DIR)
	curl -fSL -o $(FIRMWARE_DIR)/BOOTLOONGARCH64.EFI \
		https://retrage.github.io/edk2-nightly/bin/RELEASELOONGARCH64_Shell.efi
	@echo "[ZirconOSAero] Installed: $(FIRMWARE_DIR)/BOOTLOONGARCH64.EFI"

# ══════════════════════════════════════════════════════
#  Tests
# ══════════════════════════════════════════════════════

test: test-kernel test-config test-boot
	@echo "[ZirconOSAero] All tests complete."

test-kernel: build
	@echo "[ZirconOSAero] Running kernel verification tests..."
	@mkdir -p $(TEST_RESULTS_DIR)
	python3 $(ROOT_DIR)/tests/run_all.py \
		--kernel $(KERNEL_ELF) \
		--output-dir $(TEST_RESULTS_DIR)

# 无头 QEMU 烟测（需已安装 qemu-system-x86_64）；串口字节数见脚本输出。
smoke-qemu-mbr:
	@bash $(ROOT_DIR)/scripts/smoke-qemu-mbr.sh

test-config:
	@echo "[ZirconOSAero] Running build configuration tests..."
	@mkdir -p $(TEST_RESULTS_DIR)
	python3 $(ROOT_DIR)/tests/test_build_config.py \
		--project-root $(ROOT_DIR) \
		--output-dir $(TEST_RESULTS_DIR)

test-boot:
	@echo "[ZirconOSAero] Running boot combination tests..."
	@mkdir -p $(TEST_RESULTS_DIR)
	python3 $(ROOT_DIR)/tests/test_boot_combinations.py \
		--project-root $(ROOT_DIR) \
		--output-dir $(TEST_RESULTS_DIR)

# ══════════════════════════════════════════════════════
#  Clean
# ══════════════════════════════════════════════════════

clean:
	@echo "[ZirconOSAero] Cleaning..."
	rm -rf $(BUILD_DIR)
	rm -rf $(ROOT_DIR)/.zig-cache $(ROOT_DIR)/zig-out
	@for theme in aero; do \
		dir="$(ROOT_DIR)/src/desktop/$$theme"; \
		[ -d "$$dir" ] && rm -rf "$$dir/.zig-cache" "$$dir/zig-out" 2>/dev/null; \
	done || true
	@echo "[ZirconOSAero] Clean done"
