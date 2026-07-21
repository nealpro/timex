const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const app_dirs = native_sdk.app_dirs;

const model_mod = @import("model.zig");
const store_client = @import("store_client.zig");
const theme = @import("theme.zig");
const view_mod = @import("view.zig");

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const update = model_mod.update;
pub const rootView = view_mod.rootView;

pub const canvas_label = "timex-canvas";
pub const window_width: f32 = 1040;
pub const window_height: f32 = 700;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Timex canvas", .accessibility_label = "Timex", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Timex",
    .width = window_width,
    .height = window_height,
    .min_width = 920,
    .min_height = 600,
    .restore_state = false,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const TimexApp = native_sdk.UiApp(Model, Msg);

pub const app_fonts = [_]TimexApp.FontRegistration{.{
    .id = theme.primary_font_id,
    .name = "GeistPixel-Square.ttf",
    .ttf = @embedFile("fonts/GeistPixel-Square.ttf"),
}};

pub fn tokensFromModel(model: *const Model) canvas.DesignTokens {
    return theme.tokens(model.high_contrast, model.reduce_motion);
}

pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

pub fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return .{ .appearance_changed = appearance };
}

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(TimexApp);
    defer std.heap.page_allocator.destroy(app_state);

    var model = model_mod.initialModel();
    var path_buffer: [store_client.max_path_bytes]u8 = undefined;
    if (resolveDbPath(init, &path_buffer)) |path| model.setStorePath(path);
    var bin_buffer: [store_client.max_path_bytes]u8 = undefined;
    if (resolveStoreBin(init, &bin_buffer)) |path| model.setStoreBin(path);

    app_state.* = TimexApp.init(std.heap.page_allocator, model, .{
        .name = "timex",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = model_mod.boot,
        .view = rootView,
        .fonts = &app_fonts,
        .tokens_fn = tokensFromModel,
        .on_appearance = onAppearance,
        .on_chrome = onChrome,
    });
    defer app_state.deinit();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "timex",
        .window_title = "Timex",
        .bundle_id = "dev.native_sdk.timex",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

pub fn resolveDbPath(init: std.process.Init, output: []u8) ?[]const u8 {
    const env = native_sdk.debug.envFromMap(init.environ_map);
    if (init.environ_map.get("TIMEX_DB_PATH")) |override| return copyPath(output, override);
    const platform = app_dirs.currentPlatform();
    var dir_buffer: [store_client.max_path_bytes]u8 = undefined;
    const data_dir = app_dirs.resolveOne(.{ .name = "timex" }, platform, env, .data, &dir_buffer) catch return copyPath(output, ".zig-cache/timex.sqlite");
    makePath(init.io, data_dir) catch {};
    return app_dirs.join(platform, output, &.{ data_dir, "timex.sqlite" }) catch null;
}

pub fn resolveStoreBin(init: std.process.Init, output: []u8) ?[]const u8 {
    if (init.environ_map.get("TIMEX_STORE_BIN")) |override| return copyPath(output, override);
    return copyPath(output, "zig-out/bin/timex-store");
}

fn copyPath(output: []u8, path: []const u8) ?[]const u8 {
    if (path.len > output.len) return null;
    @memcpy(output[0..path.len], path);
    return output[0..path.len];
}

fn makePath(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

test {
    _ = store_client;
}
