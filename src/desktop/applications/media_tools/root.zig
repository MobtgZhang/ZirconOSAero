// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/media_tools/root.zig
// Purpose: Root module for Media Tools applications
//
// This is an independent clean-room implementation.

pub const photo_gallery = @import("photo_gallery.zig");

pub const PhotoGalleryApp = photo_gallery.PhotoGalleryApp;
pub const PhotoItem = photo_gallery.PhotoItem;
pub const GalleryView = photo_gallery.GalleryView;
