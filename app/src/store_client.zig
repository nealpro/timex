const std = @import("std");

pub const max_projects = 48;
pub const max_timers = 128;
pub const max_name_bytes = 64;
pub const max_label_bytes = 96;
pub const max_path_bytes = 1024;

pub const Status = enum { paused, running };

pub const Project = struct {
    id: i64 = 0,
    name_storage: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    created_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,

    pub fn name(project: *const Project) []const u8 {
        return project.name_storage[0..project.name_len];
    }

    pub fn setName(project: *Project, value: []const u8) void {
        const len = @min(value.len, max_name_bytes);
        @memcpy(project.name_storage[0..len], value[0..len]);
        project.name_len = len;
    }
};

pub const Timer = struct {
    id: i64 = 0,
    project_id: i64 = 0,
    label_storage: [max_label_bytes]u8 = undefined,
    label_len: usize = 0,
    status: Status = .paused,
    accumulated_ms: i64 = 0,
    started_at_ms: i64 = 0,
    created_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
    elapsed_ms: i64 = 0,

    pub fn label(timer: *const Timer) []const u8 {
        return timer.label_storage[0..timer.label_len];
    }

    pub fn setLabel(timer: *Timer, value: []const u8) void {
        const len = @min(value.len, max_label_bytes);
        @memcpy(timer.label_storage[0..len], value[0..len]);
        timer.label_len = len;
    }

    pub fn elapsedMs(timer: *const Timer, now_ms: i64) i64 {
        _ = now_ms;
        return timer.elapsed_ms;
    }
};

pub const Snapshot = struct {
    projects: [max_projects]Project = undefined,
    project_count: usize = 0,
    timers: [max_timers]Timer = undefined,
    timer_count: usize = 0,
    selected_project_id: i64 = 0,
    revision: i64 = 0,
};

pub fn parseSnapshot(json_text: []const u8) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json_text, .{});
    if (root != .object) return error.InvalidSnapshot;

    var out = Snapshot{};
    out.revision = intMember(root, "revision") orelse 0;
    out.selected_project_id = intMember(root, "selected_project_id") orelse 0;

    if (root.object.get("projects")) |projects_value| {
        if (projects_value != .array) return error.InvalidSnapshot;
        for (projects_value.array.items) |project_value| {
            if (out.project_count >= max_projects) break;
            if (project_value != .object) return error.InvalidSnapshot;
            var project = Project{
                .id = intMember(project_value, "id") orelse return error.InvalidSnapshot,
                .created_at_ms = intMember(project_value, "created_at_ms") orelse 0,
                .updated_at_ms = intMember(project_value, "updated_at_ms") orelse 0,
            };
            project.setName(stringMember(project_value, "name") orelse "");
            out.projects[out.project_count] = project;
            out.project_count += 1;
        }
    }

    if (root.object.get("timers")) |timers_value| {
        if (timers_value != .array) return error.InvalidSnapshot;
        for (timers_value.array.items) |timer_value| {
            if (out.timer_count >= max_timers) break;
            if (timer_value != .object) return error.InvalidSnapshot;
            var timer = Timer{
                .id = intMember(timer_value, "id") orelse return error.InvalidSnapshot,
                .project_id = intMember(timer_value, "project_id") orelse return error.InvalidSnapshot,
                .status = if (std.mem.eql(u8, stringMember(timer_value, "status") orelse "paused", "running")) .running else .paused,
                .accumulated_ms = intMember(timer_value, "accumulated_ms") orelse 0,
                .started_at_ms = intMember(timer_value, "started_at_ms") orelse 0,
                .created_at_ms = intMember(timer_value, "created_at_ms") orelse 0,
                .updated_at_ms = intMember(timer_value, "updated_at_ms") orelse 0,
                .elapsed_ms = intMember(timer_value, "elapsed_ms") orelse 0,
            };
            timer.setLabel(stringMember(timer_value, "label") orelse "");
            out.timers[out.timer_count] = timer;
            out.timer_count += 1;
        }
    }

    return out;
}

fn intMember(value: std.json.Value, name: []const u8) ?i64 {
    if (value != .object) return null;
    const member = value.object.get(name) orelse return null;
    return switch (member) {
        .integer => |integer| integer,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn stringMember(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const member = value.object.get(name) orelse return null;
    return switch (member) {
        .string => |text| text,
        else => null,
    };
}

test "parse snapshot" {
    const snapshot = try parseSnapshot(
        \\{"revision":2,"selected_project_id":1,"projects":[{"id":1,"name":"Core","created_at_ms":10,"updated_at_ms":11}],"timers":[{"id":7,"project_id":1,"label":"Plan","status":"running","accumulated_ms":100,"started_at_ms":20,"created_at_ms":12,"updated_at_ms":13,"elapsed_ms":120}]}
    );
    try std.testing.expectEqual(@as(usize, 1), snapshot.project_count);
    try std.testing.expectEqualStrings("Core", snapshot.projects[0].name());
    try std.testing.expectEqual(@as(usize, 1), snapshot.timer_count);
    try std.testing.expectEqual(Status.running, snapshot.timers[0].status);
}
