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
// Module: src/desktop/applications/mail/root.zig
// Purpose: Root module for Mail/Calendar applications
//
// This is an independent clean-room implementation.

pub const mail = @import("mail.zig");
pub const calendar = @import("calendar.zig");

pub const MailApp = mail.MailApp;
pub const CalendarApp = calendar.CalendarApp;
pub const MailMessage = mail.MailMessage;
pub const CalendarEvent = calendar.CalendarEvent;
pub const MailFolder = mail.MailFolder;
pub const CalendarView = calendar.CalendarView;
