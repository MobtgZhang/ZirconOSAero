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
