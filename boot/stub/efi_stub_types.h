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

/* Minimal UEFI types for ZirconOS boot stub - no gnu-efi */
#pragma once

typedef unsigned char UINT8;
typedef unsigned short UINT16;
typedef unsigned int UINT32;
typedef unsigned long long UINT64;
typedef unsigned long long UINTN;
typedef UINT16 CHAR16;
typedef unsigned char BOOLEAN;
typedef void VOID;

typedef UINTN EFI_STATUS;
typedef VOID *EFI_HANDLE;
typedef UINT64 EFI_PHYSICAL_ADDRESS;

#define EFI_SUCCESS 0ULL
#define EFI_LOAD_ERROR ((1ULL<<63)|1)
#define EFI_INVALID_PARAMETER ((1ULL<<63)|2)
#define EFI_UNSUPPORTED ((1ULL<<63)|3)
#define EFI_NOT_READY ((1ULL<<63)|6)

typedef enum {
	AllocateAnyPages,
	AllocateMaxAddress,
	AllocateAddress,
} EFI_ALLOCATE_TYPE;

typedef enum {
	EfiLoaderCode,
	EfiLoaderData,
} EFI_MEMORY_TYPE;

typedef EFI_STATUS (*EFI_ALLOCATE_PAGES)(EFI_ALLOCATE_TYPE, EFI_MEMORY_TYPE, UINTN, EFI_PHYSICAL_ADDRESS *);
typedef EFI_STATUS (*EFI_FREE_PAGES)(EFI_PHYSICAL_ADDRESS, UINTN);
typedef EFI_STATUS (*EFI_GET_MEMORY_MAP)(UINTN *, VOID *, UINTN *, UINTN *, UINT32 *);
typedef EFI_STATUS (*EFI_ALLOCATE_POOL)(EFI_MEMORY_TYPE, UINTN, VOID **);
typedef EFI_STATUS (*EFI_EXIT_BOOT_SERVICES)(EFI_HANDLE, UINTN);

typedef EFI_STATUS (*EFI_TEXT_RESET)(VOID *This, BOOLEAN Extend);
typedef EFI_STATUS (*EFI_TEXT_STRING)(VOID *This, CHAR16 *String);
typedef EFI_STATUS (*EFI_TEXT_CLEAR)(VOID *This);
typedef EFI_STATUS (*EFI_TEXT_SET_ATTR)(VOID *This, UINTN Attribute);
typedef EFI_STATUS (*EFI_TEXT_SET_CURSOR)(VOID *This, UINTN Col, UINTN Row);
typedef EFI_STATUS (*EFI_TEXT_ENABLE_CURSOR)(VOID *This, BOOLEAN Visible);

typedef EFI_STATUS (*EFI_STALL)(UINTN Microseconds);
typedef EFI_STATUS (*EFI_WAIT_FOR_EVENT)(UINTN NumberOfEvents, VOID **Event, UINTN *Index);

typedef struct {
	EFI_TEXT_RESET Reset;
	EFI_TEXT_STRING OutputString;
	VOID *TestString;
	VOID *QueryMode;
	VOID *SetMode;
	EFI_TEXT_SET_ATTR SetAttribute;
	EFI_TEXT_CLEAR ClearScreen;
	EFI_TEXT_SET_CURSOR SetCursorPosition;
	EFI_TEXT_ENABLE_CURSOR EnableCursor;
	VOID *Mode;
} EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;

typedef struct {
	UINT16 ScanCode;
	CHAR16 UnicodeChar;
} EFI_INPUT_KEY;

typedef EFI_STATUS (*EFI_INPUT_READ_KEY)(VOID *This, EFI_INPUT_KEY *Key);

typedef struct {
	VOID *Reset;
	EFI_INPUT_READ_KEY ReadKeyStroke;
	VOID *WaitForKey;
} EFI_SIMPLE_TEXT_INPUT_PROTOCOL;

typedef EFI_STATUS (*EFI_FILE_OPEN)(VOID *This, VOID **NewHandle, CHAR16 *FileName, UINT64 OpenMode, UINT64 Attributes);
typedef EFI_STATUS (*EFI_FILE_CLOSE)(VOID *This);
typedef EFI_STATUS (*EFI_FILE_READ)(VOID *This, UINTN *BufferSize, VOID *Buffer);

typedef struct {
	UINT64 Revision;
	EFI_FILE_OPEN Open;
	EFI_FILE_CLOSE Close;
	VOID *Delete;
	EFI_FILE_READ Read;
	VOID *Write;
	VOID *GetPosition;
	VOID *SetPosition;
	VOID *GetInfo;
	VOID *SetInfo;
	VOID *Flush;
} EFI_FILE_PROTOCOL;

typedef EFI_STATUS (*EFI_OPEN_VOLUME)(VOID *This, EFI_FILE_PROTOCOL **Root);

typedef struct {
	UINT64 Revision;
	EFI_OPEN_VOLUME OpenVolume;
} EFI_SIMPLE_FILE_SYSTEM_PROTOCOL;

typedef EFI_STATUS (*EFI_HANDLE_PROTOCOL)(EFI_HANDLE, VOID *Protocol, VOID **Interface);

typedef struct {
	UINT64 Signature;
	UINT32 Revision;
	UINT32 HeaderSize;
	UINT32 CRC32;
	UINT32 Reserved;
} EFI_TABLE_HEADER;

typedef struct {
	EFI_TABLE_HEADER Hdr;
	VOID *RaiseTPL;
	VOID *RestoreTPL;
	EFI_ALLOCATE_PAGES AllocatePages;
	EFI_FREE_PAGES FreePages;
	EFI_GET_MEMORY_MAP GetMemoryMap;
	EFI_ALLOCATE_POOL AllocatePool;
	VOID *FreePool;
	VOID *CreateEvent;
	VOID *SetTimer;
	VOID *WaitForEvent;
	VOID *SignalEvent;
	VOID *CloseEvent;
	VOID *CheckEvent;
	VOID *InstallProtocolInterface;
	VOID *ReinstallProtocolInterface;
	VOID *UninstallProtocolInterface;
	EFI_HANDLE_PROTOCOL HandleProtocol;
	VOID *Reserved;
	VOID *RegisterProtocolNotify;
	VOID *LocateHandle;
	VOID *LocateDevicePath;
	VOID *InstallConfigurationTable;
	VOID *LoadImage;
	VOID *StartImage;
	VOID *Exit;
	VOID *UnloadImage;
	EFI_EXIT_BOOT_SERVICES ExitBootServices;
	VOID *GetNextMonotonicCount;
	EFI_STALL Stall;
	VOID *SetWatchdogTimer;
	VOID *ConnectController;
	VOID *DisconnectController;
	VOID *OpenProtocol;
	VOID *CloseProtocol;
	VOID *OpenProtocolInformation;
	VOID *ProtocolsPerHandle;
	VOID *LocateHandleBuffer;
	VOID *LocateProtocol;
	VOID *InstallMultipleProtocolInterfaces;
	VOID *UninstallMultipleProtocolInterfaces;
} EFI_BOOT_SERVICES;

typedef struct {
	EFI_TABLE_HEADER Hdr;
	CHAR16 *FirmwareVendor;
	UINT32 FirmwareRevision;
	EFI_HANDLE ConsoleInHandle;
	EFI_SIMPLE_TEXT_INPUT_PROTOCOL *ConIn;
	EFI_HANDLE ConsoleOutHandle;
	EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *ConOut;
	EFI_HANDLE StandardErrorHandle;
	VOID *StdErr;
	VOID *RuntimeServices;
	EFI_BOOT_SERVICES *BootServices;
	UINTN NumberOfTableEntries;
	VOID *ConfigurationTable;
} EFI_SYSTEM_TABLE;

typedef struct {
	UINT32 Data1;
	UINT16 Data2;
	UINT16 Data3;
	UINT8 Data4[8];
} EFI_GUID;

typedef EFI_STATUS (*EFI_LOCATE_PROTOCOL)(EFI_GUID *Protocol, VOID *Registration, VOID **Interface);

#define EFI_FILE_MODE_READ 0x0000000000000001ULL
#define EFI_LOADED_IMAGE_PROTOCOL_GUID { 0x5b1b31a1, 0x9562, 0x11d2, { 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#define EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID { 0x964e5b22, 0x6459, 0x11d2, { 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#define EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID { 0x9042a9de, 0x23dc, 0x4a38, { 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a } }

/* GOP Mode Information */
typedef struct {
	UINT32 Version;
	UINT32 HorizontalResolution;
	UINT32 VerticalResolution;
	UINT32 PixelFormat;
	UINT32 PixelInformation[4];
	UINT32 PixelsPerScanLine;
} EFI_GRAPHICS_OUTPUT_MODE_INFO;

typedef struct {
	UINT32 MaxMode;
	UINT32 Mode;
	EFI_GRAPHICS_OUTPUT_MODE_INFO *Info;
	UINTN SizeOfInfo;
	EFI_PHYSICAL_ADDRESS FrameBufferBase;
	UINTN FrameBufferSize;
} EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE;

typedef struct {
	VOID *QueryMode;
	VOID *SetMode;
	VOID *Blt;
	EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *Mode;
} EFI_GRAPHICS_OUTPUT_PROTOCOL;

/* ELF64 */
typedef struct {
	UINT8 e_ident[16];
	UINT16 e_type;
	UINT16 e_machine;
	UINT32 e_version;
	UINT64 e_entry;
	UINT64 e_phoff;
	UINT64 e_shoff;
	UINT32 e_flags;
	UINT16 e_ehsize;
	UINT16 e_phentsize;
	UINT16 e_phnum;
	UINT16 e_shentsize;
	UINT16 e_shnum;
	UINT16 e_shstrndx;
} Elf64_Ehdr;

typedef struct {
	UINT32 p_type;
	UINT32 p_flags;
	UINT64 p_offset;
	UINT64 p_vaddr;
	UINT64 p_paddr;
	UINT64 p_filesz;
	UINT64 p_memsz;
	UINT64 p_align;
} Elf64_Phdr;
