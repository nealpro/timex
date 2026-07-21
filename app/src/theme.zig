const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const Color = canvas.Color;

pub const primary_font_id: canvas.FontId = canvas.min_registered_font_id;
pub const pixel_grid_em: f32 = 1000.0 / 38.0;
pub const pixel_grid_half_em: f32 = pixel_grid_em / 2.0;
pub const body_size: f32 = pixel_grid_half_em;

pub fn tokens(high_contrast: bool, reduce_motion: bool) canvas.DesignTokens {
    var out = canvas.DesignTokens.theme(.{
        .color_scheme = .light,
        .contrast = if (high_contrast) .high else .standard,
        .density = .compact,
        .reduce_motion = reduce_motion,
    });
    out.pixel_snap = .{ .geometry = true, .text = true, .scale = 1 };
    if (high_contrast) return out;

    out.colors = .{
        .background = glass,
        .surface = enamel,
        .surface_subtle = glass_lifted,
        .surface_pressed = key_pressed,
        .text = ink,
        .text_muted = engraving,
        .border = putty_line,
        .accent = phosphor,
        .accent_text = Color.rgb8(7, 21, 13),
        .destructive = Color.rgb8(196, 60, 46),
        .destructive_text = Color.rgb8(250, 246, 236),
        .success = phosphor_pale,
        .success_text = Color.rgb8(7, 21, 13),
        .warning = Color.rgb8(236, 178, 74),
        .warning_text = Color.rgb8(43, 30, 7),
        .info = phosphor_dim,
        .info_text = Color.rgb8(7, 21, 13),
        .focus_ring = phosphor,
        .shadow = Color.rgba8(0, 0, 0, 0),
        .disabled = disabled_wash,
    };
    out.radius = .{ .sm = 2, .md = 3, .lg = 4, .xl = 5 };
    out.typography.font_id = primary_font_id;
    out.typography.mono_font_id = primary_font_id;
    out.typography.body_size = body_size;
    out.typography.label_size = pixel_grid_half_em;
    out.typography.title_size = pixel_grid_em;
    out.typography.button_size = pixel_grid_half_em;
    out.controls.button_outline = .{
        .background = key_face,
        .hover_background = key_hover,
        .active_background = key_pressed,
        .foreground = ink,
        .border = key_edge,
    };
    out.controls.button_primary = out.controls.button_outline;
    out.controls.button_ghost = .{
        .hover_background = key_hover,
        .active_background = key_pressed,
        .foreground = ink,
    };
    out.controls.search_field = .{
        .background = glass,
        .foreground = phosphor_pale,
        .border = hairline,
    };
    out.controls.panel = .{
        .background = Color.rgba8(0, 0, 0, 0),
        .border = Color.rgba8(0, 0, 0, 0),
    };
    return out;
}

const enamel = Color.rgb8(231, 225, 209);
const key_face = Color.rgb8(238, 232, 217);
const key_hover = Color.rgb8(245, 240, 227);
const key_pressed = Color.rgb8(212, 204, 184);
const key_edge = Color.rgb8(158, 150, 128);
const ink = Color.rgb8(44, 40, 32);
const engraving = Color.rgb8(110, 102, 82);
const putty_line = Color.rgb8(169, 161, 138);
const disabled_wash = Color.rgb8(222, 215, 198);
pub const glass = Color.rgb8(12, 16, 13);
const glass_lifted = Color.rgb8(24, 40, 30);
pub const phosphor = Color.rgb8(62, 224, 138);
const phosphor_pale = Color.rgb8(168, 216, 180);
const phosphor_dim = Color.rgb8(96, 128, 106);
const hairline = Color.rgb8(56, 68, 58);
