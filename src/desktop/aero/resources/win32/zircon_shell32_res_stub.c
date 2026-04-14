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
