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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/fs/initfs_registry.zig
// Purpose: Built-in registry hive data for InitFS
//
// Contains registry hive content for system initialization.

pub const SYSTEM_HIVE_CONTENT =
    "[HKEY_LOCAL_MACHINE\\system]\r\n" ++
    "[HKEY_LOCAL_MACHINE\\system\\Select]\r\n" ++
    "\"Default\"=dword:00000001\r\n" ++
    "\"Current\"=dword:00000001\r\n" ++
    "[HKEY_LOCAL_MACHINE\\system\\ControlSet001]\r\n" ++
    "\"Version\"=\"6.1.7601.22693\"\r\n" ++
    "[HKEY_LOCAL_MACHINE\\system\\ControlSet001\\Control]\r\n" ++
    "\"SystemStartOptions\"=\"FASTDETECT\"\r\n" ++
    "[HKEY_LOCAL_MACHINE\\system\\ControlSet001\\Services]\r\n" ++
    "[HKEY_LOCAL_MACHINE\\system\\ControlSet001\\Services\\Tcpip]\r\n" ++
    "\"Type\"=dword:00000001\r\n" ++
    "\"Start\"=dword:00000002\r\n" ++
    "\"DisplayName\"=\"TCP/IP Protocol Driver\"\r\n" ++
    "[HKEY_LOCAL_MACHINE\\system\\ControlSet001\\Services\\Tcpip\\Parameters]\r\n" ++
    "\"Hostname\"=\"ZirconOSAero\"\r\n" ++
    "\"Domain\"=\"\"\r\n";

pub const SOFTWARE_HIVE_CONTENT =
    "[HKEY_LOCAL_MACHINE\\software\\ZirconOS\\CurrentVersion]\r\n" ++
    "\"ProgramFilesDir\"=\"C:\\Program Files\"\r\n" ++
    "\"ProgramFilesDir (x86)\"=\"C:\\Program Files (x86)\"\r\n" ++
    "\"Version\"=\"6.1.7601\"\r\n" ++
    "\"SystemRoot\"=\"C:\\Windows\"\r\n" ++
    "\"RegisteredOrganization\"=\"ZirconOS\"\r\n" ++
    "\"RegisteredOwner\"=\"Administrator\"\r\n" ++
    "[HKEY_LOCAL_MACHINE\\software\\ZirconOS\\NT\\CurrentVersion]\r\n" ++
    "\"SystemRoot\"=\"C:\\Windows\"\r\n" ++
    "\"CurrentVersion\"=\"6.1\"\r\n" ++
    "\"ProductName\"=\"ZirconOSAero\"\r\n" ++
    "\"EditionID\"=\"Ultimate\"\r\n" ++
    "\"BuildLab\"=\"7601.zirconos_gdr\"\r\n" ++
    "[HKEY_LOCAL_MACHINE\\software\\ZirconOS\\NT\\CurrentVersion\\Winlogon]\r\n" ++
    "\"Shell\"=\"explorer.exe\"\r\n" ++
    "\"Userinit\"=\"C:\\Windows\\System32\\userinit.exe,\"\r\n";

pub const DEFAULT_USER_REGISTRY =
    "[HKEY_CURRENT_USER]\r\n" ++
    "[HKEY_CURRENT_USER\\Software]\r\n" ++
    "[HKEY_CURRENT_USER\\Software\\ZirconOS]\r\n" ++
    "[HKEY_CURRENT_USER\\Software\\ZirconOS\\Desktop]\r\n" ++
    "[HKEY_CURRENT_USER\\Software\\ZirconOS\\Desktop\\CurrentVersion]\r\n" ++
    "[HKEY_CURRENT_USER\\Control Panel]\r\n" ++
    "[HKEY_CURRENT_USER\\Control Panel\\Colors]\r\n" ++
    "\"Background\"=\"58 110 165\"\r\n" ++
    "[HKEY_CURRENT_USER\\Control Panel\\Desktop]\r\n" ++
    "\"Wallpaper\"=\"\"\r\n" ++
    "[HKEY_CURRENT_USER\\Console]\r\n" ++
    "\"FaceName\"=\"Consolas\"\r\n" ++
    "\"FontFamily\"=dword:00000036\r\n" ++
    "\"FontSize\"=dword:000c0000\r\n" ++
    "\"CursorColor\"=dword:00ffffff\r\n" ++
    "\"QuickEdit\"=dword:00000001\r\n" ++
    "\"HistoryBufferSize\"=dword:00000032\r\n";
