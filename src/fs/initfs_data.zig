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
// Module: src/fs/initfs_data.zig
// Purpose: Built-in file content for InitFS
//
// Contains the actual file content for critical system files.

pub const HOSTS_FILE =
    "# Copyright (c) 2024 ZirconOS Project\r\n" ++
    "# This is a sample HOSTS file used by ZirconOS TCP/IP stack.\r\n" ++
    "# localhost name resolution is handled within DNS itself.\r\n" ++
    "127.0.0.1       localhost\r\n" ++
    "::1             localhost\r\n" ++
    "# ZirconOSAero Network Configuration\r\n" ++
    "127.0.0.1       localhost\r\n" ++
    "::1             localhost\r\n";

pub const SERVICES_FILE =
    "# Copyright (c) 2024 ZirconOS Project\r\n" ++
    "# Service name and port number registry.\r\n" ++
    "# Format: <service name> <port number>/<protocol>\r\n" ++
    "echo            7/tcp\r\n" ++
    "discard         9/tcp\r\n" ++
    "daytime         13/tcp\r\n" ++
    "qotd            17/tcp\r\n" ++
    "ftp             21/tcp\r\n" ++
    "telnet          23/tcp\r\n" ++
    "smtp            25/tcp\r\n" ++
    "dns             53/tcp\r\n" ++
    "dns             53/udp\r\n" ++
    "dhcp            67/udp\r\n" ++
    "tftp            69/udp\r\n" ++
    "http            80/tcp\r\n" ++
    "pop3            110/tcp\r\n" ++
    "ntp             123/udp\r\n" ++
    "imap            143/tcp\r\n" ++
    "https           443/tcp\r\n" ++
    "smb             445/tcp\r\n" ++
    "mysql           3306/tcp\r\n" ++
    "postgresql      5432/tcp\r\n" ++
    "mssql           1433/tcp\r\n" ++
    "rdp             3389/tcp\r\n";

pub const NETWORKS_FILE =
    "# Copyright (c) 2024 ZirconOS Project\r\n" ++
    "# Network number information for mapping network names.\r\n" ++
    "# Format: <network name> <network number>\r\n" ++
    "loopback        127\r\n" ++
    "localnet        192.168.0\r\n" ++
    "ZirconOS        192.168.1\r\n";

pub const PROTOCOL_FILE =
    "# Copyright (c) 2024 ZirconOS Project\r\n" ++
    "# Protocol number database.\r\n" ++
    "ip              0               IP\r\n" ++
    "icmp            1               ICMP\r\n" ++
    "igmp            2               IGMP\r\n" ++
    "tcp             6               TCP\r\n" ++
    "udp             17              UDP\r\n" ++
    "ipv6-icmp       58              ICMPv6\r\n" ++
    "esp             50              IPSEC-ESP\r\n" ++
    "ah              51              IPSEC-AH\r\n";

pub const AUTOEXEC_BAT =
    "@echo off\r\n" ++
    "REM ZirconOSAero AutoExec Batch File\r\n" ++
    "prompt $P$G\r\n" ++
    "set TEMP=C:\\Windows\\Temp\r\n" ++
    "set TMP=C:\\Windows\\Temp\r\n" ++
    "echo Welcome to ZirconOSAero NT 6.1\r\n";

pub const CONFIG_SYS =
    "; ZirconOSAero CONFIG.SYS\r\n" ++
    "[boot]\r\n" ++
    "shell=cmd.exe /k\r\n" ++
    "[display]\r\n" ++
    "resolution=1440x900x32\r\n";

pub const LMHOSTS_SMB_FILE =
    "# Copyright (c) 2024 ZirconOS Project\r\n" ++
    "# NetBIOS domain, name, and address mappings.\r\n" ++
    "# Format: <IP address> <16th character NetBIOS name>\r\n" ++
    "127.0.0.1       localhost\r\n";
