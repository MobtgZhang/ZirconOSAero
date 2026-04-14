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
