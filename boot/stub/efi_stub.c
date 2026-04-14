// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

/*
 * ZirconOSAero Boot Manager (ZBM) — Windows 7 风格启动菜单 (LoongArch64 UEFI)
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
#define SCAN_F8 0x12
#define SCAN_ESC 0x17
#define UNICODE_UP 0x2191   /* ↑ */
#define UNICODE_DOWN 0x2193 /* ↓ */

#define EFI_ABORTED ((1ULL << 63) | 21ULL)

typedef EFI_STATUS (*EFI_BS_EXIT)(EFI_HANDLE, EFI_STATUS, UINTN, VOID *);
typedef EFI_STATUS (*EFI_WAIT_FOR_EVENT)(UINTN, VOID **, UINTN *);

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
/* 0 = OS entries, 1 = Tools (Win7-style TAB) */
static int menu_focus = 0;
static UINTN tool_selected = 0;
static const CHAR16 *const tool_desc[1] = { L"ZirconOS Memory Diagnostic" };
#define TOOL_COUNT 1

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

#define CON_COLS 80
#define LINE_MAX 78

static const CHAR16 spaces_79[80] = {
	L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ',
	L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ',
	L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ',
	L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ',
	L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', L' ', 0
};

static void clear_line(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con, UINTN row, UINTN n) {
	(void)n;
	if (!con) return;
	con->SetCursorPosition(con, 0, row);
	con->OutputString(con, (CHAR16 *)spaces_79);
	con->SetCursorPosition(con, 0, row);
}

static void print_line_padded(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con, const CHAR16 *prefix, const CHAR16 *desc) {
	CHAR16 buf[80];
	UINTN i = 0;
	if (!con) return;
	while (prefix[i]) {
		buf[i] = prefix[i];
		i++;
	}
	while (*desc && i < LINE_MAX) buf[i++] = *desc++;
	while (i < LINE_MAX) buf[i++] = L' ';
	buf[i] = 0;
	con->OutputString(con, buf);
}

#define ROW_ENTRY_FIRST 5U
#define MENU_ENTRY_ROW(i) (ROW_ENTRY_FIRST + (UINTN)(i))
#define ROW_F8_LINE (6U + entry_count)
#define BOOT_TIMER_ROW (8U + entry_count)
#define ROW_TOOLS_LABEL (10U + entry_count)
#define ROW_TOOLS_FIRST (11U + entry_count)
#define ROW_FOOTER 24U

static void draw_grey_bar_title(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con) {
	UINTN col;
	if (!con) return;
	con->SetCursorPosition(con, 0, 0);
	con->SetAttribute(con, ATTR_HIGHLIGHT);
	con->OutputString(con, (CHAR16 *)spaces_79);
	col = (80U - 25U) / 2U; /* "ZirconOSAero Boot Manager" */
	con->SetCursorPosition(con, col, 0);
	print(con, L"ZirconOSAero Boot Manager");
	con->SetAttribute(con, ATTR_NORMAL);
}

static void draw_footer_bar_win7(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con) {
	if (!con) return;
	con->SetCursorPosition(con, 0, ROW_FOOTER);
	con->SetAttribute(con, ATTR_HIGHLIGHT);
	con->OutputString(con, (CHAR16 *)spaces_79);
	con->SetCursorPosition(con, 2, ROW_FOOTER);
	print(con, L"ENTER=Choose");
	con->SetCursorPosition(con, (80U - 8U) / 2U, ROW_FOOTER);
	print(con, L"TAB=Menu");
	con->SetCursorPosition(con, 80U - 11U - 1U, ROW_FOOTER);
	print(con, L"ESC=Cancel");
	con->SetAttribute(con, ATTR_NORMAL);
}

/* 78 列高亮行，描述左对齐，右侧 `>` */
static void print_os_line_highlighted(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con, const CHAR16 *desc) {
	CHAR16 buf[80];
	UINTN i = 0;
	UINTN left = 4;
	if (!con) return;
	while (i < left) buf[i++] = L' ';
	while (*desc && i < LINE_MAX - 2) buf[i++] = *desc++;
	while (i < LINE_MAX - 1) buf[i++] = L' ';
	buf[LINE_MAX - 1] = L'>';
	buf[LINE_MAX] = 0;
	con->SetAttribute(con, ATTR_HIGHLIGHT);
	con->OutputString(con, buf);
	con->SetAttribute(con, ATTR_NORMAL);
}

static void redraw_os_rows(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con) {
	UINTN i, row;
	if (!con) return;
	for (i = 0; i < entry_count; i++) {
		row = MENU_ENTRY_ROW(i);
		clear_line(con, row, CON_COLS);
		con->SetCursorPosition(con, 0, row);
		if (menu_focus == 0 && i == selected)
			print_os_line_highlighted(con, (CHAR16 *)entries[i].desc);
		else {
			con->SetAttribute(con, ATTR_NORMAL);
			print_line_padded(con, L"    ", (CHAR16 *)entries[i].desc);
		}
	}
}

static void redraw_tool_rows(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con) {
	UINTN t, row;
	if (!con) return;
	for (t = 0; t < TOOL_COUNT; t++) {
		row = ROW_TOOLS_FIRST + t;
		clear_line(con, row, CON_COLS);
		con->SetCursorPosition(con, 0, row);
		if (menu_focus == 1 && t == tool_selected)
			print_os_line_highlighted(con, tool_desc[t]);
		else {
			con->SetAttribute(con, ATTR_NORMAL);
			print_line_padded(con, L"    ", (CHAR16 *)tool_desc[t]);
		}
	}
}

static void display_menu(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con) {
	UINTN r;
	UINTN gap;
	if (!con) return;
	con->Reset(con, 0);
	con->SetAttribute(con, ATTR_NORMAL);

	draw_grey_bar_title(con);
	clear_line(con, 1, CON_COLS);

	con->SetCursorPosition(con, 0, 2);
	con->SetAttribute(con, ATTR_NORMAL);
	print(con, L"    Choose an operating system to start, or press TAB to select a tool:\r\n");
	con->SetCursorPosition(con, 0, 3);
	con->SetAttribute(con, ATTR_DIM);
	print(con, L"    (Use the arrow keys to highlight your choice, then press ENTER.)\r\n");
	clear_line(con, 4, CON_COLS);

	redraw_os_rows(con);

	gap = 5U + entry_count;
	clear_line(con, gap, CON_COLS);

	con->SetCursorPosition(con, 0, ROW_F8_LINE);
	con->SetAttribute(con, ATTR_NORMAL);
	print(con, L"    To specify an advanced option for this choice, press F8.\r\n");
	clear_line(con, ROW_F8_LINE + 1U, CON_COLS);

	if (timer_active && countdown > 0) {
		con->SetCursorPosition(con, 0, BOOT_TIMER_ROW);
		con->SetAttribute(con, ATTR_NORMAL);
		print(con, L"    Seconds until the highlighted choice will be started automatically: ");
		print_dec(con, countdown);
		print(con, L"\r\n");
	} else {
		clear_line(con, BOOT_TIMER_ROW, CON_COLS);
	}

	clear_line(con, BOOT_TIMER_ROW + 1U, CON_COLS);

	con->SetCursorPosition(con, 0, ROW_TOOLS_LABEL);
	con->SetAttribute(con, ATTR_NORMAL);
	print(con, L"    Tools:\r\n");
	redraw_tool_rows(con);

	for (r = ROW_TOOLS_FIRST + TOOL_COUNT; r < ROW_FOOTER; r++)
		clear_line(con, r, CON_COLS);

	draw_footer_bar_win7(con);
	con->EnableCursor(con, 0);
}

static void show_tool_placeholder(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con, EFI_BOOT_SERVICES *bs,
				    EFI_SIMPLE_TEXT_INPUT_PROTOCOL *con_in) {
	if (!con) return;
	con->Reset(con, 0);
	con->SetAttribute(con, ATTR_NORMAL);
	print(con, L"\r\n    ZirconOS Boot Manager\r\n\r\n");
	print(con, L"    The selected tool is not available in this C stub build.\r\n\r\n");
	print(con, L"    Press any key to return...\r\n");
	if (con_in && bs) {
		UINTN index = 0;
		((EFI_WAIT_FOR_EVENT)bs->WaitForEvent)(1, (VOID **)&con_in->WaitForKey, &index);
	}
}

static void show_f8_placeholder(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con, EFI_BOOT_SERVICES *bs,
				EFI_SIMPLE_TEXT_INPUT_PROTOCOL *con_in) {
	if (!con) return;
	con->Reset(con, 0);
	con->SetAttribute(con, ATTR_NORMAL);
	print(con, L"\r\n    Advanced boot options (C stub)\r\n\r\n");
	print(con, L"    Full BCD / firmware details are available in the Zig ZBM (BOOTLOONGARCH64 from zig build).\r\n\r\n");
	print(con, L"    Press any key to return to the boot menu...\r\n");
	if (con_in && bs) {
		UINTN index = 0;
		((EFI_WAIT_FOR_EVENT)bs->WaitForEvent)(1, (VOID **)&con_in->WaitForKey, &index);
	}
}

static void update_selection_only(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *con, UINTN old_sel, UINTN new_sel) {
	(void)old_sel;
	(void)new_sel;
	if (!con) return;
	redraw_os_rows(con);
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

	/* Boot Manager menu loop (Win7-style: TAB / F8 / ESC) */
	{
		UINTN last_selected = (UINTN)-1;
		UINTN last_tool = (UINTN)-1;
		int last_focus = -1;
		UINTN poll_count = 0;
		BOOLEAN need_full = 1;

		while (1) {
			if (need_full || last_focus != menu_focus) {
				display_menu(con);
				need_full = 0;
				last_focus = menu_focus;
				last_selected = selected;
				last_tool = tool_selected;
			} else if (menu_focus == 0 && last_selected != selected) {
				update_selection_only(con, last_selected, selected);
				last_selected = selected;
			} else if (menu_focus == 1 && last_tool != tool_selected) {
				redraw_tool_rows(con);
				last_tool = tool_selected;
			}

			if (con_in) {
				EFI_INPUT_KEY key;
				EFI_STATUS kst = con_in->ReadKeyStroke(con_in, &key);
				if (kst == EFI_SUCCESS) {
					timer_active = 0;

					if (key.UnicodeChar == u'\t') {
						menu_focus = (menu_focus == 0) ? 1 : 0;
						continue;
					}
					if (key.ScanCode == SCAN_ESC) {
						((EFI_BS_EXIT)bs->Exit)(image_handle, (EFI_STATUS)EFI_ABORTED, 0, (VOID *)0);
						for (;;) {}
					}
					if (key.ScanCode == SCAN_F8) {
						show_f8_placeholder(con, bs, con_in);
						need_full = 1;
						continue;
					}

					if (menu_focus == 1) {
						if ((key.ScanCode == SCAN_UP || key.ScanCode == SCAN_UP_EXT ||
						     key.UnicodeChar == UNICODE_UP || key.UnicodeChar == u'k' || key.UnicodeChar == u'w') &&
						    tool_selected > 0)
							tool_selected--;
						else if ((key.ScanCode == SCAN_DOWN || key.ScanCode == SCAN_DOWN_EXT ||
						          key.UnicodeChar == UNICODE_DOWN || key.UnicodeChar == u'j' || key.UnicodeChar == u's') &&
						         tool_selected + 1 < TOOL_COUNT)
							tool_selected++;
						else if (key.UnicodeChar == u'\r' || key.UnicodeChar == u'\n') {
							show_tool_placeholder(con, bs, con_in);
							need_full = 1;
						}
						continue;
					}

					if ((key.ScanCode == SCAN_UP || key.ScanCode == SCAN_UP_EXT ||
					     key.UnicodeChar == UNICODE_UP || key.UnicodeChar == u'k' || key.UnicodeChar == u'w') &&
					    selected > 0)
						selected--;
					else if ((key.ScanCode == SCAN_DOWN || key.ScanCode == SCAN_DOWN_EXT ||
					          key.UnicodeChar == UNICODE_DOWN || key.UnicodeChar == u'j' || key.UnicodeChar == u's') &&
					         selected + 1 < entry_count)
						selected++;
					else if (key.UnicodeChar == u'\r' || key.UnicodeChar == u'\n')
						break;
					else if (key.UnicodeChar >= u'1' && key.UnicodeChar <= u'6') {
						UINTN idx = (UINTN)(key.UnicodeChar - u'1');
						if (idx < entry_count) {
							selected = idx;
							break;
						}
					}
					continue;
				}
			}

			if (timer_active) {
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
				UINTN index = 0;
				((EFI_WAIT_FOR_EVENT)bs->WaitForEvent)(1, (VOID **)&con_in->WaitForKey, &index);
			} else {
				bs->Stall(100000);
			}
		}
	}

	con->Reset(con, 0);
	con->SetAttribute(con, ATTR_NORMAL);
	print(con, L"\r\n");
	print(con, L"                    ZirconOSAero Boot Manager (ZBM)                         \r\n");
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
