const std = @import("std");
const native_sdk = @import("native_sdk");
const store_mod = @import("store.zig");

const canvas = native_sdk.canvas;

pub const Store = store_mod.Store;
pub const Project = store_mod.Project;
pub const Timer = store_mod.Timer;

pub const tick_timer_key: u64 = 1;
pub const tick_interval_ms: u32 = 1000;
pub const header_natural_height: f32 = 52;

pub const Msg = union(enum) {
    project_edit: canvas.TextInputEvent,
    timer_edit: canvas.TextInputEvent,
    create_project,
    select_project: i64,
    create_timer,
    start_timer: i64,
    pause_timer: i64,
    delete_timer: i64,
    refresh_tick: native_sdk.EffectTimer,
    chrome_changed: native_sdk.WindowChrome,
    appearance_changed: native_sdk.Appearance,

    pub const view_unbound = .{ "refresh_tick", "chrome_changed", "appearance_changed" };
};

pub const Model = struct {
    store_path_storage: [store_mod.max_path_bytes]u8 = undefined,
    store_path_len: usize = 0,
    projects: [store_mod.max_projects]Project = undefined,
    project_count: usize = 0,
    timers: [store_mod.max_timers]Timer = undefined,
    timer_count: usize = 0,
    selected_project_id: i64 = 0,
    revision: i64 = -1,
    now_ms: i64 = 0,
    project_field: canvas.TextBuffer(store_mod.max_name_bytes) = .{},
    timer_field: canvas.TextBuffer(store_mod.max_label_bytes) = .{},
    status_storage: [160]u8 = undefined,
    status_len: usize = 0,
    chrome_leading: f32 = 0,
    header_height: f32 = header_natural_height,
    high_contrast: bool = false,
    reduce_motion: bool = false,

    pub const view_unbound = .{
        "store_path_storage", "store_path_len", "projects", "project_count",
        "timers", "timer_count", "revision", "now_ms", "project_field",
        "timer_field", "status_storage", "status_len", "chrome_leading",
        "header_height", "high_contrast", "reduce_motion", "storePath",
    };

    pub fn storePath(model: *const Model) []const u8 {
        return model.store_path_storage[0..model.store_path_len];
    }

    pub fn setStorePath(model: *Model, path: []const u8) void {
        const len = @min(path.len, model.store_path_storage.len);
        @memcpy(model.store_path_storage[0..len], path[0..len]);
        model.store_path_len = len;
    }

    pub fn projectDraft(model: *const Model) []const u8 {
        return model.project_field.text();
    }

    pub fn timerDraft(model: *const Model) []const u8 {
        return model.timer_field.text();
    }

    pub fn selectedProject(model: *const Model) ?*const Project {
        for (model.projects[0..model.project_count]) |*project| {
            if (project.id == model.selected_project_id) return project;
        }
        return null;
    }

    pub fn selectedProjectName(model: *const Model) []const u8 {
        return if (model.selectedProject()) |project| project.name() else "NO PROJECT";
    }

    pub fn hasSelectedProject(model: *const Model) bool {
        return model.selectedProject() != null;
    }

    pub fn projectDraftEmpty(model: *const Model) bool {
        return std.mem.trim(u8, model.projectDraft(), " \t\r\n").len == 0;
    }

    pub fn timerDraftEmpty(model: *const Model) bool {
        return std.mem.trim(u8, model.timerDraft(), " \t\r\n").len == 0 or !model.hasSelectedProject();
    }

    pub fn status(model: *const Model) []const u8 {
        if (model.status_len == 0) return "READY";
        return model.status_storage[0..model.status_len];
    }

    pub fn runningCount(model: *const Model) usize {
        var count: usize = 0;
        for (model.timers[0..model.timer_count]) |*timer| {
            if (timer.status == .running) count += 1;
        }
        return count;
    }

    fn setStatus(model: *Model, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&model.status_storage, fmt, args) catch "STATUS BUFFER FULL";
        model.status_len = text.len;
    }

    fn load(model: *Model) !void {
        if (model.store_path_len == 0) return;
        var store = try Store.open(model.storePath());
        defer store.close();
        const snapshot = try store.load();
        model.projects = snapshot.projects;
        model.project_count = snapshot.project_count;
        model.timers = snapshot.timers;
        model.timer_count = snapshot.timer_count;
        model.selected_project_id = snapshot.selected_project_id;
        model.revision = snapshot.revision;
    }
};

pub const Effects = native_sdk.UiApp(Model, Msg).Effects;

pub fn initialModel() Model {
    return .{};
}

pub fn boot(model: *Model, fx: *Effects) void {
    model.now_ms = fx.wallMs();
    model.load() catch model.setStatus("DATABASE UNAVAILABLE", .{});
    fx.startTimer(.{
        .key = tick_timer_key,
        .interval_ms = tick_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.refresh_tick),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    model.now_ms = fx.wallMs();
    switch (msg) {
        .project_edit => |edit| model.project_field.apply(edit),
        .timer_edit => |edit| model.timer_field.apply(edit),
        .create_project => createProject(model),
        .select_project => |id| selectProject(model, id),
        .create_timer => createTimer(model),
        .start_timer => |id| mutateTimer(model, id, .start),
        .pause_timer => |id| mutateTimer(model, id, .pause),
        .delete_timer => |id| mutateTimer(model, id, .delete),
        .refresh_tick => model.load() catch {},
        .chrome_changed => |chrome| {
            model.chrome_leading = chrome.insets.left;
            model.header_height = @max(header_natural_height, chrome.insets.top);
        },
        .appearance_changed => |appearance| {
            model.high_contrast = appearance.high_contrast;
            model.reduce_motion = appearance.reduce_motion;
        },
    }
}

fn createProject(model: *Model) void {
    var store = Store.open(model.storePath()) catch return model.setStatus("DATABASE UNAVAILABLE", .{});
    defer store.close();
    const name = model.projectDraft();
    _ = store.createProject(name, model.now_ms) catch |err| return model.setStatus("PROJECT ERROR: {s}", .{@errorName(err)});
    model.project_field.clear();
    model.load() catch {};
    model.setStatus("PROJECT CREATED", .{});
}

fn selectProject(model: *Model, id: i64) void {
    var store = Store.open(model.storePath()) catch return model.setStatus("DATABASE UNAVAILABLE", .{});
    defer store.close();
    store.setSelectedProject(id) catch |err| return model.setStatus("SELECT ERROR: {s}", .{@errorName(err)});
    model.load() catch {};
    model.setStatus("PROJECT SELECTED", .{});
}

fn createTimer(model: *Model) void {
    if (model.selected_project_id == 0) return model.setStatus("SELECT PROJECT FIRST", .{});
    var store = Store.open(model.storePath()) catch return model.setStatus("DATABASE UNAVAILABLE", .{});
    defer store.close();
    _ = store.createTimer(model.selected_project_id, model.timerDraft(), model.now_ms) catch |err| return model.setStatus("TIMER ERROR: {s}", .{@errorName(err)});
    model.timer_field.clear();
    model.load() catch {};
    model.setStatus("TIMER CREATED", .{});
}

const TimerAction = enum { start, pause, delete };

fn mutateTimer(model: *Model, id: i64, action: TimerAction) void {
    var store = Store.open(model.storePath()) catch return model.setStatus("DATABASE UNAVAILABLE", .{});
    defer store.close();
    (switch (action) {
        .start => store.startTimer(id, model.now_ms),
        .pause => store.pauseTimer(id, model.now_ms),
        .delete => store.deleteTimer(id),
    }) catch |err| return model.setStatus("TIMER ERROR: {s}", .{@errorName(err)});
    model.load() catch {};
    switch (action) {
        .start => model.setStatus("TIMER RUNNING", .{}),
        .pause => model.setStatus("TIMER PAUSED", .{}),
        .delete => model.setStatus("TIMER DELETED", .{}),
    }
}

pub fn formatDuration(buffer: []u8, ms: i64) []const u8 {
    const total_seconds: i64 = @divTrunc(@max(@as(i64, 0), ms), 1000);
    const hours = @divTrunc(total_seconds, 3600);
    const minutes = @divTrunc(@mod(total_seconds, 3600), 60);
    const seconds = @mod(total_seconds, 60);
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "--:--:--";
}
