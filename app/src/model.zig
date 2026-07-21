const std = @import("std");
const native_sdk = @import("native_sdk");
const store_client = @import("store_client.zig");

const canvas = native_sdk.canvas;

pub const Project = store_client.Project;
pub const Timer = store_client.Timer;

pub const tick_timer_key: u64 = 1;
pub const store_spawn_key: u64 = 2;
pub const tick_interval_ms: u32 = 1000;
pub const header_natural_height: f32 = 52;

const PendingStoreAction = enum {
    none,
    snapshot,
    project_create,
    project_select,
    timer_create,
    timer_start,
    timer_pause,
    timer_delete,
};

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
    store_done: native_sdk.EffectExit,
    chrome_changed: native_sdk.WindowChrome,
    appearance_changed: native_sdk.Appearance,

    pub const view_unbound = .{ "refresh_tick", "store_done", "chrome_changed", "appearance_changed" };
};

pub const Model = struct {
    store_path_storage: [store_client.max_path_bytes]u8 = undefined,
    store_path_len: usize = 0,
    store_bin_storage: [store_client.max_path_bytes]u8 = undefined,
    store_bin_len: usize = 0,
    projects: [store_client.max_projects]Project = undefined,
    project_count: usize = 0,
    timers: [store_client.max_timers]Timer = undefined,
    timer_count: usize = 0,
    selected_project_id: i64 = 0,
    revision: i64 = -1,
    now_ms: i64 = 0,
    project_field: canvas.TextBuffer(store_client.max_name_bytes) = .{},
    timer_field: canvas.TextBuffer(store_client.max_label_bytes) = .{},
    status_storage: [160]u8 = undefined,
    status_len: usize = 0,
    store_inflight: bool = false,
    pending_store_action: PendingStoreAction = .none,
    chrome_leading: f32 = 0,
    header_height: f32 = header_natural_height,
    high_contrast: bool = false,
    reduce_motion: bool = false,

    pub const view_unbound = .{
        "store_path_storage", "store_path_len", "store_bin_storage",
        "store_bin_len", "projects", "project_count", "timers",
        "timer_count", "revision", "now_ms", "project_field",
        "timer_field", "status_storage", "status_len", "store_inflight",
        "pending_store_action", "chrome_leading", "header_height",
        "high_contrast", "reduce_motion", "storePath", "storeBin",
    };

    pub fn storePath(model: *const Model) []const u8 {
        return model.store_path_storage[0..model.store_path_len];
    }

    pub fn setStorePath(model: *Model, path: []const u8) void {
        const len = @min(path.len, model.store_path_storage.len);
        @memcpy(model.store_path_storage[0..len], path[0..len]);
        model.store_path_len = len;
    }

    pub fn storeBin(model: *const Model) []const u8 {
        return model.store_bin_storage[0..model.store_bin_len];
    }

    pub fn setStoreBin(model: *Model, path: []const u8) void {
        const len = @min(path.len, model.store_bin_storage.len);
        @memcpy(model.store_bin_storage[0..len], path[0..len]);
        model.store_bin_len = len;
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

    fn applySnapshot(model: *Model, snapshot: store_client.Snapshot) void {
        model.projects = snapshot.projects;
        model.project_count = snapshot.project_count;
        model.timers = snapshot.timers;
        model.timer_count = snapshot.timer_count;
        model.selected_project_id = snapshot.selected_project_id;
        model.revision = snapshot.revision;
    }

    fn applyStoreExit(model: *Model, exit: native_sdk.EffectExit) void {
        model.store_inflight = false;
        const action = model.pending_store_action;
        model.pending_store_action = .none;
        if (exit.reason != .exited or exit.code != 0 or exit.output_truncated) {
            return model.setStatus("STORE ERROR: {s}", .{@tagName(exit.reason)});
        }
        const snapshot = store_client.parseSnapshot(exit.output) catch |err| {
            return model.setStatus("STORE SNAPSHOT ERROR: {s}", .{@errorName(err)});
        };
        model.applySnapshot(snapshot);
        switch (action) {
            .none, .snapshot => {},
            .project_create => {
                model.project_field.clear();
                model.setStatus("PROJECT CREATED", .{});
            },
            .project_select => model.setStatus("PROJECT SELECTED", .{}),
            .timer_create => {
                model.timer_field.clear();
                model.setStatus("TIMER CREATED", .{});
            },
            .timer_start => model.setStatus("TIMER RUNNING", .{}),
            .timer_pause => model.setStatus("TIMER PAUSED", .{}),
            .timer_delete => model.setStatus("TIMER DELETED", .{}),
        }
    }
};

pub const Effects = native_sdk.UiApp(Model, Msg).Effects;

pub fn initialModel() Model {
    return .{};
}

pub fn boot(model: *Model, fx: *Effects) void {
    model.now_ms = fx.wallMs();
    spawnSnapshot(model, fx);
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
        .create_project => createProject(model, fx),
        .select_project => |id| selectProject(model, fx, id),
        .create_timer => createTimer(model, fx),
        .start_timer => |id| mutateTimer(model, fx, id, .start),
        .pause_timer => |id| mutateTimer(model, fx, id, .pause),
        .delete_timer => |id| mutateTimer(model, fx, id, .delete),
        .refresh_tick => spawnSnapshot(model, fx),
        .store_done => |exit| model.applyStoreExit(exit),
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

fn createProject(model: *Model, fx: *Effects) void {
    const name = model.projectDraft();
    if (std.mem.trim(u8, name, " \t\r\n").len == 0) return;
    spawnStore(model, fx, .project_create, &.{ model.storeBin(), "project-create", "--db", model.storePath(), "--name", name });
}

fn selectProject(model: *Model, fx: *Effects, id: i64) void {
    var id_buffer: [32]u8 = undefined;
    const id_text = std.fmt.bufPrint(&id_buffer, "{d}", .{id}) catch return;
    spawnStore(model, fx, .project_select, &.{ model.storeBin(), "project-select", "--db", model.storePath(), "--project-id", id_text });
}

fn createTimer(model: *Model, fx: *Effects) void {
    if (model.selected_project_id == 0) return model.setStatus("SELECT PROJECT FIRST", .{});
    const label = model.timerDraft();
    if (std.mem.trim(u8, label, " \t\r\n").len == 0) return;
    var id_buffer: [32]u8 = undefined;
    const project_id = std.fmt.bufPrint(&id_buffer, "{d}", .{model.selected_project_id}) catch return;
    spawnStore(model, fx, .timer_create, &.{ model.storeBin(), "timer-create", "--db", model.storePath(), "--project-id", project_id, "--label", label });
}

const TimerAction = enum { start, pause, delete };

fn mutateTimer(model: *Model, fx: *Effects, id: i64, action: TimerAction) void {
    var id_buffer: [32]u8 = undefined;
    const id_text = std.fmt.bufPrint(&id_buffer, "{d}", .{id}) catch return;
    const command = switch (action) {
        .start => "timer-start",
        .pause => "timer-pause",
        .delete => "timer-delete",
    };
    const pending: PendingStoreAction = switch (action) {
        .start => .timer_start,
        .pause => .timer_pause,
        .delete => .timer_delete,
    };
    spawnStore(model, fx, pending, &.{ model.storeBin(), command, "--db", model.storePath(), "--timer-id", id_text });
}

fn spawnSnapshot(model: *Model, fx: *Effects) void {
    spawnStore(model, fx, .snapshot, &.{ model.storeBin(), "snapshot", "--db", model.storePath() });
}

fn spawnStore(model: *Model, fx: *Effects, action: PendingStoreAction, argv: []const []const u8) void {
    if (model.store_inflight) return;
    if (model.store_bin_len == 0 or model.store_path_len == 0) {
        return model.setStatus("STORE NOT CONFIGURED", .{});
    }
    model.store_inflight = true;
    model.pending_store_action = action;
    fx.spawn(.{
        .key = store_spawn_key,
        .argv = argv,
        .output = .collect,
        .on_exit = Effects.exitMsg(.store_done),
    });
}

pub fn formatDuration(buffer: []u8, ms: i64) []const u8 {
    const total_seconds: i64 = @divTrunc(@max(@as(i64, 0), ms), 1000);
    const hours = @divTrunc(total_seconds, 3600);
    const minutes = @divTrunc(@mod(total_seconds, 3600), 60);
    const seconds = @mod(total_seconds, 60);
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "--:--:--";
}
