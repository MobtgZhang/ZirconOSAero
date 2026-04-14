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

//! Material rendering system — kernel framebuffer rendering path.

pub const material = @import("material.zig");

pub const MaterialType = material.MaterialType;
pub const GlassConfig = material.GlassConfig;
pub const AcrylicConfig = material.AcrylicConfig;
pub const MicaConfig = material.MicaConfig;
pub const init = material.init;
pub const configureGlass = material.configureGlass;
pub const configureAcrylic = material.configureAcrylic;
pub const configureMica = material.configureMica;
pub const renderGlass = material.renderGlass;
pub const renderAcrylic = material.renderAcrylic;
pub const renderMica = material.renderMica;
pub const renderAcrylic2 = material.renderAcrylic2;
pub const renderRevealHighlight = material.renderRevealHighlight;
pub const renderShadow = material.renderShadow;
pub const applyRoundedClipAA = material.applyRoundedClipAA;
pub const applyRoundedClip = material.applyRoundedClip;
pub const isInitialized = material.isInitialized;
pub const getActiveMaterial = material.getActiveMaterial;
pub const getGlassConfig = material.getGlassConfig;
pub const getAcrylicConfig = material.getAcrylicConfig;
pub const getMicaConfig = material.getMicaConfig;
