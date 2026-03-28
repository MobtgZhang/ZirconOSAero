/*
 * ZirconOS Boot Manager — Windows 7 风格启动菜单 (LoongArch64 UEFI)
 * AevOS-style build (no gnu-efi)，固件可加载；显示 ZBM 菜单后引导内核。
 */
#include "efi_stub_types.h"

#define KERNEL_PATH u"\\boot\\kernel.elf"
#define ZIRCON_MAGIC 0x6372697A
#define HANDOFF_PHYS 0x100000
#define PT_LOAD 1
#define EM_LOONGARCH 258
#define ZBM_VERSION L"6.1"
#define DEFAULT_TIMEOUT 10
#define MAX_ENTRIES 8

#define ATTR_NORMAL 0x0F
#define ATTR_DIM 0x07
#define ATTR_HIGHLIGHT 0x70
#define ATTR_BORDER 0x08

#define SCAN_UP 0x01
#define SCAN_DOWN 0x02
#define SCAN_UP_EXT 0x48    /* PC keyboard set 1 extended */
#define SCAN_DOWN_EXT 0x50
#define SCAN_ENTER 0x0D
#define SCAN_ESC 0x17
#define UNICODE_UP 0x2191   /* ↑ */
#define UNICODE_DOWN 0x2193 /* ↓ */

/* 首选分辨率：make build 时由 sync_resolution_config.py 写入 build/tmp/zircon_pref_fb.h（-I 该目录） */
#include "zircon_pref_fb.h"

typedef struct {
	UINT32 magic;
	UINT32 version;
	UINT32 boot_mode;
	UINT32 desktop;
	/* v2: GOP framebuffer (set before ExitBootServices) */
	UINT64 fb_addr;
	UINT32 fb_pitch;
	UINT32 fb_width;
	UINT32 fb_height;
	UINT8 fb_bpp;
	UINT8 _pad[3];
	UINT32 mmap_count;
	UINT32 mmap_entry_size;
	UINT32 mmap_off_from_handoff;
	UINT32 _mmap_pad;
} EfiHandoff;

static const EFI_GUID gop_guid = { 0x9042a9de, 0x23dc, 0x4a38, { 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a } };

typedef struct {
	const CHAR16 *desc;
	UINT32 boot_mode;
	UINT32 desktop;
} MenuEntry;

static MenuEntry entries[MAX_ENTRIES];
static UINTN entry_count = 0;
static UINTN selected = 0;
static UINT32 countdown = DEFAULT_TIMEOUT;
static BOOLEAN timer_active = 1;

static void *memset(void *s, int c, UINTN n) {
	UINT8 *p = (UINT8 *)s;
	while (n--) *p++ = (UINT8)c;
	return s;
}

static void *memcpy(void *dst, const void *src, UINTN n) {
	UINT8 *d = (UINT8 *)dst;
	const UINT8 *s = (const UINT8 *)src;
	while (n--) *d++ = *s++;
	return dst;
}

static void print(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con, const CHAR16 *s) {
	if (con) con->OutputString(con, (CHAR16 *)s);
}

static void print_dec(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con, UINT32 val) {
	CHAR16 buf[12];
	UINTN i = 0;
	if (val == 0) { buf[i++] = u'0'; }
	else while (val > 0) { buf[i++] = (CHAR16)(u'0' + (val % 10)); val /= 10; }
	while (i > 0) {
		CHAR16 c[2] = { buf[--i], 0 };
		con->OutputString(con, c);
	}
}

/* UEFI: PixelRedGreenBlueReserved8BitPerColor=0, BGR=1, BitMask=2, BltOnly=3 */
static int gop_pixel_linear(UINT32 fmt) {
	return (int)(fmt <= 2u);
}

typedef EFI_STATUS (*GOP_QUERY_MODE)(EFI_GRAPHICS_OUTPUT_PROTOCOL *, UINT32, UINTN *, EFI_GRAPHICS_OUTPUT_MODE_INFO **);
typedef EFI_STATUS (*GOP_SET_MODE)(EFI_GRAPHICS_OUTPUT_PROTOCOL *, UINT32);

/* 与 boot/zbm/uefi/main_loongarch64.zig trySetPreferredGopMode 一致：精确首选 → 不小于首选的最小面积 → 最大线性 */
static void gop_try_preferred_mode(
	EFI_GRAPHICS_OUTPUT_PROTOCOL *gop,
	GOP_QUERY_MODE qm,
	GOP_SET_MODE sm,
	UINT32 pref_w,
	UINT32 pref_h)
{
	UINT32 m;
	UINTN sz;
	EFI_GRAPHICS_OUTPUT_MODE_INFO *mi;

	for (m = 0; m < gop->Mode->MaxMode; m++) {
		sz = 0;
		mi = 0;
		if (qm(gop, m, &sz, &mi) != EFI_SUCCESS || !mi) continue;
		if (!gop_pixel_linear(mi->PixelFormat)) continue;
		if (mi->HorizontalResolution == pref_w && mi->VerticalResolution == pref_h) {
			sm(gop, m);
			return;
		}
	}

	UINT32 best_m = 0xFFFFFFFFu;
	UINT64 best_px = (UINT64)-1;
	for (m = 0; m < gop->Mode->MaxMode; m++) {
		sz = 0;
		mi = 0;
		if (qm(gop, m, &sz, &mi) != EFI_SUCCESS || !mi) continue;
		if (!gop_pixel_linear(mi->PixelFormat)) continue;
		UINT32 w = mi->HorizontalResolution, h = mi->VerticalResolution;
		if (w < pref_w || h < pref_h) continue;
		UINT64 px = (UINT64)w * (UINT64)h;
		if (px < best_px) {
			best_px = px;
			best_m = m;
		}
	}
	if (best_m != 0xFFFFFFFFu) {
		sm(gop, best_m);
		return;
	}

	best_m = 0xFFFFFFFFu;
	UINT64 max_px = 0;
	for (m = 0; m < gop->Mode->MaxMode; m++) {
		sz = 0;
		mi = 0;
		if (qm(gop, m, &sz, &mi) != EFI_SUCCESS || !mi) continue;
		if (!gop_pixel_linear(mi->PixelFormat)) continue;
		UINT64 px = (UINT64)mi->HorizontalResolution * (UINT64)mi->VerticalResolution;
		if (px > max_px) {
			max_px = px;
			best_m = m;
		}
	}
	if (best_m != 0xFFFFFFFFu)
		sm(gop, best_m);
}

static void init_entries(void) {
	entries[0].desc = L"ZirconOSAero (NT 6.1)";
	entries[0].boot_mode = 0;
	entries[0].desktop = 1;
	entries[1].desc = L"ZirconOSAero (NT 6.1) [Debug Mode]";
	entries[1].boot_mode = 0;
	entries[1].desktop = 1;
	entries[2].desc = L"ZirconOSAero [Safe Mode]";
	entries[2].boot_mode = 0;
	entries[2].desktop = 0;
	entries[3].desc = L"ZirconOSAero [Safe Mode with Networking]";
	entries[3].boot_mode = 0;
	entries[3].desktop = 0;
	entries[4].desc = L"ZirconOSAero [Recovery Console]";
	entries[4].boot_mode = 0;
	entries[4].desktop = 0;
	entries[5].desc = L"ZirconOSAero [CMD Shell]";
	entries[5].boot_mode = 1;
	entries[5].desktop = 0;
	entry_count = 6;
}

static void display_menu(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con) {
	UINTN i;
	if (!con) return;
	con->Reset(con, 0);
	con->SetAttribute(con, ATTR_NORMAL);

	print(con, L"\r\n");
	print(con, L"                    ZirconOS Boot Manager                                     \r\n");
	print(con, L"                         Version ");
	print(con, ZBM_VERSION);
	print(con, L"                                             \r\n");
	print(con, L"\r\n");
	print(con, L"    Choose an operating system to start:\r\n");
	con->SetAttribute(con, ATTR_DIM);
	print(con, L"    (Use the arrow keys to highlight your choice, then press ENTER.)\r\n");
	print(con, L"\r\n");

	for (i = 0; i < entry_count; i++) {
		if (i == selected) {
			con->SetAttribute(con, ATTR_HIGHLIGHT);
			print(con, L"  > ");
		} else {
			con->SetAttribute(con, ATTR_NORMAL);
			print(con, L"    ");
		}
		print(con, (CHAR16 *)entries[i].desc);
		print(con, L"\r\n");
	}

	con->SetAttribute(con, ATTR_NORMAL);
	print(con, L"\r\n");
	con->SetAttribute(con, ATTR_BORDER);
	print(con, L"    ------------------------------------------------------------------------\r\n\r\n");

	if (timer_active && countdown > 0) {
		con->SetAttribute(con, ATTR_NORMAL);
		print(con, L"    Seconds until the highlighted choice will be started automatically: ");
		print_dec(con, countdown);
		print(con, L"\r\n");
	}

	con->SetAttribute(con, ATTR_DIM);
	print(con, L"\r\n");
	if (selected == 0) print(con, L"    Start ZirconOS normally.");
	else if (selected == 1) print(con, L"    Start with debug logging and serial output enabled.");
	else if (selected == 2) print(con, L"    Start with minimal drivers and services.");
	else if (selected == 3) print(con, L"    Start in safe mode with network support.");
	else if (selected == 4) print(con, L"    Start the Recovery Console for system repair.");
	else if (selected == 5) print(con, L"    Launch the command-line shell.");
	print(con, L"\r\n");

	con->SetAttribute(con, ATTR_NORMAL);
	print(con, L"\r\n");
	print(con, L"  ENTER=Choose  |  ESC=Advanced Options  |  F1=Help                          \r\n");
	con->SetAttribute(con, ATTR_DIM);
	print(con, L"\r\n");
	print(con, L"    Architecture: loongarch64  |  Boot: UEFI\r\n");

	con->EnableCursor(con, 0);
}

#define MENU_ENTRY_ROW(i) (7U + (i))
#define MENU_LAST_ROW (MENU_ENTRY_ROW(entry_count - 1))
#define ROW_BELOW_MENU (MENU_LAST_ROW + 1U)
#define BOOT_TIMER_ROW (11U + entry_count)
#define BOOT_DESC_ROW ((timer_active && countdown > 0) ? (BOOT_TIMER_ROW + 2U) : (BOOT_TIMER_ROW + 1U))

#define CON_COLS 80

/* 79 空格缓冲区，单次 OutputString 清除整行，减少调用次数提速 */
static const CHAR16 spaces_79[80] = {
	L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ',
	L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ',
	L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ',
	L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ',
	L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', 0
};

/* 清除单行：79 空格不换行，避免 80 列换行到下一行造成重复显示 */
static void clear_line(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con, UINTN row, UINTN n) {
	(void)n;
	con->SetCursorPosition(con, 0, row);
	con->OutputString(con, (CHAR16 *)spaces_79);
	con->SetCursorPosition(con, 0, row);
}

/* 输出一行（前缀+描述+补足78列），避免第79列换行导致重复；单次 OutputString 提速 */
#define LINE_MAX 78
static void print_line_padded(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con, const CHAR16 *prefix, const CHAR16 *desc) {
	CHAR16 buf[80];
	UINTN i = 0;
	while (prefix[i]) { buf[i] = prefix[i]; i++; }
	while (*desc && i < LINE_MAX) { buf[i++] = *desc++; }
	while (i < LINE_MAX) buf[i++] = L' ';
	buf[i] = 0;
	con->OutputString(con, buf);
}

/* 全量重绘所有菜单项+描述行；跳过菜单行清除（直接覆盖78列），仅清除空行与描述行提速 */
static void update_selection_only(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con, UINTN old_sel, UINTN new_sel) {
	UINTN i, row;
	if (!con) return;
	if (old_sel == new_sel) return;
	clear_line(con, ROW_BELOW_MENU, CON_COLS);
	clear_line(con, BOOT_DESC_ROW, CON_COLS);
	/* 直接覆盖重绘全部菜单项（78列全覆盖，无需预清除） */
	for (i = 0; i < entry_count; i++) {
		row = MENU_ENTRY_ROW(i);
		con->SetCursorPosition(con, 0, row);
		if (i == new_sel) {
			con->SetAttribute(con, ATTR_HIGHLIGHT);
			print_line_padded(con, L"  > ", entries[i].desc);
			con->SetAttribute(con, ATTR_NORMAL);
		} else {
			con->SetAttribute(con, ATTR_NORMAL);
			print_line_padded(con, L"    ", entries[i].desc);
		}
	}
	/* 更新描述行 */
	row = BOOT_DESC_ROW;
	con->SetCursorPosition(con, 0, row);
	con->SetAttribute(con, ATTR_DIM);
	if (new_sel == 0) print(con, L"    Start ZirconOS normally.");
	else if (new_sel == 1) print(con, L"    Start with debug logging and serial output enabled.");
	else if (new_sel == 2) print(con, L"    Start with minimal drivers and services.");
	else if (new_sel == 3) print(con, L"    Start in safe mode with network support.");
	else if (new_sel == 4) print(con, L"    Start the Recovery Console for system repair.");
	else if (new_sel == 5) print(con, L"    Launch the command-line shell.");
}

/* 计时器数字起始列（"    Seconds until the highlighted choice will be started automatically: " = 72 字符） */
#define TIMER_NUM_COL 72

static void refresh_timer_line(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con) {
	if (!con || !timer_active || countdown == 0) return;
	/* 只覆盖数字部分，不整行清除、不输出 \r\n，避免上滚和跳动 */
	con->SetCursorPosition(con, TIMER_NUM_COL, BOOT_TIMER_ROW);
	con->SetAttribute(con, ATTR_NORMAL);
	print_dec(con, countdown);
	print(con, L"  "); /* 覆盖 "10"->"9" 残留 */
}

static EFI_STATUS read_kernel(EFI_BOOT_SERVICES *bs, EFI_HANDLE image_handle,
	UINT8 **out_buf, UINTN *out_size)
{
	EFI_GUID lip_guid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
	EFI_GUID fs_guid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
	VOID *lip_raw = 0;
	EFI_STATUS status;

	typedef struct {
		UINT32 Revision;
		EFI_HANDLE ParentHandle;
		VOID *SystemTable;
		EFI_HANDLE DeviceHandle;
		VOID *FilePath;
		VOID *Reserved;
		UINT32 LoadOptionsSize;
		VOID *LoadOptions;
		VOID *ImageBase;
		UINT64 ImageSize;
		UINT32 ImageCodeType;
		UINT32 ImageDataType;
		VOID *Unload;
	} EFI_LOADED_IMAGE;

	status = bs->HandleProtocol(image_handle, &lip_guid, &lip_raw);
	if (status != EFI_SUCCESS) return status;

	EFI_LOADED_IMAGE *li = (EFI_LOADED_IMAGE *)lip_raw;
	EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs = 0;
	status = bs->HandleProtocol(li->DeviceHandle, &fs_guid, (VOID **)&fs);
	if (status != EFI_SUCCESS) return status;

	EFI_FILE_PROTOCOL *root = 0;
	status = fs->OpenVolume(fs, &root);
	if (status != EFI_SUCCESS) return status;

	EFI_FILE_PROTOCOL *kfile = 0;
	status = root->Open(root, (VOID **)&kfile, KERNEL_PATH, EFI_FILE_MODE_READ, 0);
	if (status != EFI_SUCCESS) {
		print(0, L"Zircon: kernel.elf not found\r\n");
		root->Close(root);
		return status;
	}

	UINTN pages = (32ULL * 1024 * 1024 + 4095) / 4096;
	EFI_PHYSICAL_ADDRESS buf = 0;
	status = bs->AllocatePages(AllocateAnyPages, EfiLoaderData, pages, &buf);
	if (status != EFI_SUCCESS) {
		kfile->Close(kfile);
		root->Close(root);
		return status;
	}

	UINTN read_sz = 32ULL * 1024 * 1024;
	status = kfile->Read(kfile, &read_sz, (VOID *)(UINTN)buf);
	kfile->Close(kfile);
	root->Close(root);
	if (status != EFI_SUCCESS) {
		bs->FreePages(buf, pages);
		return status;
	}

	*out_buf = (UINT8 *)(UINTN)buf;
	*out_size = read_sz;
	return EFI_SUCCESS;
}

static EFI_STATUS load_elf(EFI_BOOT_SERVICES *bs, UINT8 *elf_data, UINTN elf_size,
	UINT64 *entry_out)
{
	Elf64_Ehdr *ehdr = (Elf64_Ehdr *)elf_data;
	if (elf_size < sizeof(Elf64_Ehdr)) return EFI_LOAD_ERROR;
	if (ehdr->e_ident[0] != 0x7F || ehdr->e_ident[1] != 'E' ||
	    ehdr->e_ident[2] != 'L' || ehdr->e_ident[3] != 'F')
		return EFI_LOAD_ERROR;
	if (ehdr->e_machine != EM_LOONGARCH) return EFI_LOAD_ERROR;

	*entry_out = ehdr->e_entry;

	for (UINT16 i = 0; i < ehdr->e_phnum; i++) {
		Elf64_Phdr *ph = (Elf64_Phdr *)(elf_data + ehdr->e_phoff +
			(UINTN)i * ehdr->e_phentsize);
		if (ph->p_type != PT_LOAD || ph->p_memsz == 0) continue;

		UINT64 paddr = ph->p_paddr ? ph->p_paddr : ph->p_vaddr;
		UINTN pages = (UINTN)((ph->p_memsz + 4095) / 4096);

		EFI_PHYSICAL_ADDRESS alloc_addr = paddr;
		EFI_STATUS st = bs->AllocatePages(AllocateAddress, EfiLoaderData,
			pages, &alloc_addr);
		if (st != EFI_SUCCESS) {
			st = bs->AllocatePages(AllocateAnyPages, EfiLoaderData,
				pages, &alloc_addr);
			if (st != EFI_SUCCESS) return st;
		}

		memset((void *)(UINTN)alloc_addr, 0, pages * 4096);
		if (ph->p_filesz > 0 && ph->p_offset + ph->p_filesz <= elf_size)
			memcpy((void *)(UINTN)alloc_addr,
				elf_data + ph->p_offset, (UINTN)ph->p_filesz);
	}
	return EFI_SUCCESS;
}

EFI_STATUS efi_main(EFI_HANDLE image_handle, EFI_SYSTEM_TABLE *st)
{
	EFI_BOOT_SERVICES *bs = st->BootServices;
	EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con = st->ConOut;
	EFI_SIMPLE_TEXT_INPUT_PROTOCOL *con_in = st->ConIn;

	init_entries();

	if (con) con->ClearScreen(con);

	/* Boot Manager menu loop */
	{
		UINTN last_selected = (UINTN)-1;
		UINTN poll_count = 0;

		while (1) {
			if (last_selected != selected) {
				if (last_selected == (UINTN)-1) {
					display_menu(con);
				} else {
					update_selection_only(con, last_selected, selected);
				}
				last_selected = selected;
			}

			if (con_in) {
				EFI_INPUT_KEY key;
				EFI_STATUS kst = con_in->ReadKeyStroke(con_in, &key);
				if (kst == EFI_SUCCESS) {
					/* Key pressed */
					timer_active = 0;
					/* Up: EFI 0x01, extended 0x48, Unicode ↑, or k/w */
					if ((key.ScanCode == SCAN_UP || key.ScanCode == SCAN_UP_EXT ||
					     key.UnicodeChar == UNICODE_UP || key.UnicodeChar == u'k' || key.UnicodeChar == u'w') &&
					    selected > 0)
						selected--;
					/* Down: EFI 0x02, extended 0x50, Unicode ↓, or j/s */
					else if ((key.ScanCode == SCAN_DOWN || key.ScanCode == SCAN_DOWN_EXT ||
					          key.UnicodeChar == UNICODE_DOWN || key.UnicodeChar == u'j' || key.UnicodeChar == u's') &&
					         selected + 1 < entry_count)
						selected++;
					else if (key.ScanCode == SCAN_ENTER || key.UnicodeChar == u'\r' || key.UnicodeChar == u'\n')
						break;
					else if (key.UnicodeChar >= u'1' && key.UnicodeChar <= u'6') {
						UINTN idx = (UINTN)(key.UnicodeChar - u'1');
						if (idx < entry_count) { selected = idx; break; }
					}
					continue;
				}
			}

			if (timer_active) {
				/* Poll every 5ms，按键响应更快 */
				bs->Stall(5000);
				poll_count++;
				if (poll_count >= 200) {
					poll_count = 0;
					if (countdown > 0) {
						countdown--;
						refresh_timer_line(con);
						if (countdown == 0) break;
					}
				}
			} else if (con_in) {
				/* Block until key pressed when no countdown */
				UINTN index = 0;
				typedef EFI_STATUS (*EFI_WAIT_FOR_EVENT)(UINTN, VOID **, UINTN *);
				((EFI_WAIT_FOR_EVENT)bs->WaitForEvent)(1, (VOID **)&con_in->WaitForKey, &index);
			} else {
				bs->Stall(100000);
			}
		}
	}

	con->Reset(con, 0);
	con->SetAttribute(con, ATTR_NORMAL);
	print(con, L"\r\n");
	print(con, L"                    ZirconOS Boot Manager                                     \r\n");
	con->SetAttribute(con, ATTR_DIM);
	print(con, L"\r\n");
	print(con, L"    Booting: ");
	print(con, (CHAR16 *)entries[selected].desc);
	print(con, L"\r\n\r\n");
	print(con, L"    [*] Loading kernel image...\r\n\r\n");

	UINT8 *elf_buf = 0;
	UINTN elf_size = 0;
	EFI_STATUS status = read_kernel(bs, image_handle, &elf_buf, &elf_size);
	if (status != EFI_SUCCESS) {
		print(con, L"  [!!] Failed to load kernel.elf\r\n");
		for (;;) {}
	}

	UINT64 entry_point = 0;
	status = load_elf(bs, elf_buf, elf_size, &entry_point);
	if (status != EFI_SUCCESS) {
		print(con, L"  [!!] ELF load failed\r\n");
		for (;;) {}
	}

	EFI_PHYSICAL_ADDRESS ho = HANDOFF_PHYS;
	status = bs->AllocatePages(AllocateAddress, EfiLoaderData, 1, &ho);
	if (status != EFI_SUCCESS) {
		print(con, L"  [!!] Handoff alloc failed\r\n");
		for (;;) {}
	}

	EfiHandoff *hp = (EfiHandoff *)HANDOFF_PHYS;
	hp->magic = ZIRCON_MAGIC;
	hp->version = 2;
	hp->boot_mode = entries[selected].boot_mode;
	hp->desktop = entries[selected].desktop;
	hp->fb_addr = 0;
	hp->fb_pitch = 0;
	hp->fb_width = 0;
	hp->fb_height = 0;
	hp->fb_bpp = 0;

	/* 仅当 GOP 同时达到构建首选分辨率时才写入 handoff；否则内核弃用 GOP 并走 ramfb+fw_cfg（与 Zig ZBM / main.zig 一致）。 */
	{
		typedef EFI_STATUS (*LP)(EFI_GUID *Protocol, VOID *Registration, VOID **Interface);

		EFI_GRAPHICS_OUTPUT_PROTOCOL *gop = 0;
		EFI_STATUS gst = ((LP)bs->LocateProtocol)((EFI_GUID *)&gop_guid, 0, (VOID **)&gop);
		if (gst != EFI_SUCCESS || !gop || !gop->Mode || !gop->Mode->Info) {
			print(con, L"  [*] No UEFI graphics -> kernel uses ramfb + fw_cfg\r\n");
			print(con, L"      QEMU: add -device ramfb. Doc: AeroDesktopRuntime.md\r\n");
		} else {
			GOP_QUERY_MODE qm = (GOP_QUERY_MODE)gop->QueryMode;
			GOP_SET_MODE sm = (GOP_SET_MODE)gop->SetMode;
			const UINT32 pref_w = ZIRCON_PREF_FB_WIDTH;
			const UINT32 pref_h = ZIRCON_PREF_FB_HEIGHT;
			const UINT32 min_w = 1024U, min_h = 768U;

			/* Blt-only → 先切到线性模式 */
			if (!gop_pixel_linear(gop->Mode->Info->PixelFormat)) {
				UINT32 m;
				for (m = 0; m < gop->Mode->MaxMode; m++) {
					UINTN sz = 0;
					EFI_GRAPHICS_OUTPUT_MODE_INFO *mi = 0;
					if (qm(gop, m, &sz, &mi) != EFI_SUCCESS || !mi) continue;
					if (gop_pixel_linear(mi->PixelFormat) && sm(gop, m) == EFI_SUCCESS)
						break;
				}
			}

			gop_try_preferred_mode(gop, qm, sm, pref_w, pref_h);

			if (gop->Mode->Info && gop_pixel_linear(gop->Mode->Info->PixelFormat) &&
			    gop->Mode->Info->HorizontalResolution >= pref_w &&
			    gop->Mode->Info->VerticalResolution >= pref_h &&
			    gop->Mode->FrameBufferBase != 0) {
				hp->fb_addr = gop->Mode->FrameBufferBase;
				hp->fb_width = gop->Mode->Info->HorizontalResolution;
				hp->fb_height = gop->Mode->Info->VerticalResolution;
				hp->fb_pitch = gop->Mode->Info->PixelsPerScanLine * 4;
				if (hp->fb_pitch == 0)
					hp->fb_pitch = hp->fb_width * 4;
				hp->fb_bpp = 32;
				print(con, L"  [*] Handoff FB OK (build pref) ");
				print_dec(con, hp->fb_width);
				print(con, L" x ");
				print_dec(con, hp->fb_height);
				print(con, L" phys 0x");
				{
					CHAR16 hx[] = L"0123456789ABCDEF";
					CHAR16 buf[20];
					int i = 0;
					UINT64 a = hp->fb_addr;
					for (int sh = 60; sh >= 0; sh -= 4)
						buf[i++] = hx[(a >> sh) & 0xF];
					buf[i] = 0;
					print(con, buf);
				}
				print(con, L"\r\n");
			} else if (gop->Mode->Info && gop_pixel_linear(gop->Mode->Info->PixelFormat) &&
				   gop->Mode->Info->HorizontalResolution >= min_w &&
				   gop->Mode->Info->VerticalResolution >= min_h) {
				/* Firmware GOP smaller than build preferred: handoff has no FB; kernel uses ramfb+fw_cfg. */
				print(con, L"  [*] Firmware FB ");
				print_dec(con, gop->Mode->Info->HorizontalResolution);
				print(con, L" x ");
				print_dec(con, gop->Mode->Info->VerticalResolution);
				print(con, L" < pref ");
				print_dec(con, pref_w);
				print(con, L" x ");
				print_dec(con, pref_h);
				print(con, L"\r\n");
				print(con, L"  [*] Kernel uses ramfb + fw_cfg at pref size (normal).\r\n");
				print(con, L"      Serial: ramfb:  Desktop: fb  first frame. Text pane may stay small.\r\n");
			} else {
				print(con, L"  [*] FB small or non-linear -> ramfb + fw_cfg; need -device ramfb\r\n");
			}
		}
	}

	UINTN map_size = 0, map_key = 0, desc_size = 0;
	UINT32 desc_ver = 0;
	bs->GetMemoryMap(&map_size, 0, &map_key, &desc_size, &desc_ver);
	map_size += 4096;

	UINT8 *mmap_buf = 0;
	bs->AllocatePool(EfiLoaderData, map_size, (VOID **)&mmap_buf);
	bs->GetMemoryMap(&map_size, (VOID *)mmap_buf,
		&map_key, &desc_size, &desc_ver);

	for (int retry = 0; retry < 4; retry++) {
		status = bs->ExitBootServices(image_handle, map_key);
		if (status == EFI_SUCCESS) break;
		map_size = 0;
		bs->GetMemoryMap(&map_size, 0, &map_key, &desc_size, &desc_ver);
		map_size += 4096;
		bs->GetMemoryMap(&map_size, (VOID *)mmap_buf,
			&map_key, &desc_size, &desc_ver);
	}
	if (status != EFI_SUCCESS) for (;;) {}

	UINT64 tmp;
	tmp = 0x0000000000000001ULL;
	__asm__ volatile("csrwr %0, 0x180" : "+r"(tmp));
	tmp = 0x9000000000000011ULL;
	__asm__ volatile("csrwr %0, 0x181" : "+r"(tmp));
	__asm__ volatile("csrrd %0, 0x0" : "=r"(tmp));
	tmp = (tmp & ~(1ULL << 3)) | (1ULL << 4);
	__asm__ volatile("csrwr %0, 0x0" : "+r"(tmp) :: "memory");

	UINT64 mag = ZIRCON_MAGIC;
	UINT64 hand = HANDOFF_PHYS;
	typedef void (*entry_fn)(UINT64, UINT64);
	entry_fn entry = (entry_fn)(UINTN)entry_point;
	entry(mag, hand);
	for (;;) {}
}
