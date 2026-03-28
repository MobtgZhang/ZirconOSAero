/* SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * ZirconOSAero — PE resource DLL entry (host / Win32 tooling only).
 * Provides a valid DllMain so the module loads under Windows 7+ LoadLibrary
 * like any native icon resource DLL. No Microsoft code referenced.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved) {
    (void)hinst;
    (void)reason;
    (void)reserved;
    return TRUE;
}
