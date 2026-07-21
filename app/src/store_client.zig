const std = @import("std");

pub const max_projects = 48;
pub const max_timers = 128;
pub const max_name_bytes = 64;
pub const max_label_bytes = 96;
pub const max_details_bytes = 512;
pub const max_duration_bytes = 48;
pub const max_scheduled_start_bytes = 48;
pub const max_local_time_bytes = 64;
pub const max_path_bytes = 1024;

pub const Status = enum { paused, running };
pub const ScheduleState = enum { unscheduled, upcoming, waiting, consumed };

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
    details_storage: [max_details_bytes]u8 = undefined,
    details_len: usize = 0,
    scheduled_start_local_storage: [max_local_time_bytes]u8 = undefined,
    scheduled_start_local_len: usize = 0,
    planned_end_local_storage: [max_local_time_bytes]u8 = undefined,
    planned_end_local_len: usize = 0,
    duration_ms: i64 = 0,
    status: Status = .paused,
    schedule_state: ScheduleState = .unscheduled,
    accumulated_ms: i64 = 0,
    started_at_ms: i64 = 0,
    scheduled_start_ms: i64 = 0,
    planned_end_ms: i64 = 0,
    schedule_consumed_at_ms: i64 = 0,
    schedule_delay_ms: i64 = 0,
    notification_claimed_at_ms: i64 = 0,
    created_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
    elapsed_ms: i64 = 0,
    remaining_ms: i64 = 0,
    overdue_ms: i64 = 0,

    pub fn label(timer: *const Timer) []const u8 {
        return timer.label_storage[0..timer.label_len];
    }
    pub fn setLabel(timer: *Timer, value: []const u8) void {
        const len = @min(value.len, max_label_bytes);
        @memcpy(timer.label_storage[0..len], value[0..len]);
        timer.label_len = len;
    }
    pub fn details(timer: *const Timer) []const u8 {
        return timer.details_storage[0..timer.details_len];
    }
    pub fn setDetails(timer: *Timer, value: []const u8) void {
        const len = @min(value.len, max_details_bytes);
        @memcpy(timer.details_storage[0..len], value[0..len]);
        timer.details_len = len;
    }
    pub fn scheduledStartLocal(timer: *const Timer) []const u8 {
        return timer.scheduled_start_local_storage[0..timer.scheduled_start_local_len];
    }
    pub fn setScheduledStartLocal(timer: *Timer, value: []const u8) void {
        const len = @min(value.len, max_local_time_bytes);
        @memcpy(timer.scheduled_start_local_storage[0..len], value[0..len]);
        timer.scheduled_start_local_len = len;
    }
    pub fn plannedEndLocal(timer: *const Timer) []const u8 {
        return timer.planned_end_local_storage[0..timer.planned_end_local_len];
    }
    pub fn setPlannedEndLocal(timer: *Timer, value: []const u8) void {
        const len = @min(value.len, max_local_time_bytes);
        @memcpy(timer.planned_end_local_storage[0..len], value[0..len]);
        timer.planned_end_local_len = len;
    }
};

pub const Snapshot = struct {
    projects: [max_projects]Project = undefined,
    project_count: usize = 0,
    timers: [max_timers]Timer = undefined,
    timer_count: usize = 0,
    selected_project_id: i64 = 0,
    revision: i64 = 0,
    now_ms: i64 = 0,
    schema_version: i64 = 0,
};

pub fn parseSnapshot(json_text: []const u8) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json_text, .{});
    if (root != .object) return error.InvalidSnapshot;
    var out = Snapshot{};
    out.schema_version = intMember(root, "schema_version") orelse 0;
    out.revision = intMember(root, "revision") orelse 0;
    out.now_ms = intMember(root, "now_ms") orelse 0;
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
                .duration_ms = intMember(timer_value, "duration_ms") orelse return error.InvalidSnapshot,
                .status = parseStatus(stringMember(timer_value, "status") orelse "paused"),
                .schedule_state = parseScheduleState(stringMember(timer_value, "schedule_state") orelse "unscheduled"),
                .accumulated_ms = intMember(timer_value, "accumulated_ms") orelse 0,
                .started_at_ms = intMember(timer_value, "started_at_ms") orelse 0,
                .scheduled_start_ms = intMember(timer_value, "scheduled_start_ms") orelse 0,
                .planned_end_ms = intMember(timer_value, "planned_end_ms") orelse 0,
                .schedule_consumed_at_ms = intMember(timer_value, "schedule_consumed_at_ms") orelse 0,
                .schedule_delay_ms = intMember(timer_value, "schedule_delay_ms") orelse 0,
                .notification_claimed_at_ms = intMember(timer_value, "notification_claimed_at_ms") orelse 0,
                .created_at_ms = intMember(timer_value, "created_at_ms") orelse 0,
                .updated_at_ms = intMember(timer_value, "updated_at_ms") orelse 0,
                .elapsed_ms = intMember(timer_value, "elapsed_ms") orelse 0,
                .remaining_ms = intMember(timer_value, "remaining_ms") orelse 0,
                .overdue_ms = intMember(timer_value, "overdue_ms") orelse 0,
            };
            timer.setLabel(stringMember(timer_value, "label") orelse "");
            timer.setDetails(stringMember(timer_value, "details") orelse "");
            timer.setScheduledStartLocal(stringMember(timer_value, "scheduled_start_local") orelse "");
            timer.setPlannedEndLocal(stringMember(timer_value, "planned_end_local") orelse "");
            out.timers[out.timer_count] = timer;
            out.timer_count += 1;
        }
    }
    return out;
}

fn parseStatus(value: []const u8) Status {
    return if (std.mem.eql(u8, value, "running")) .running else .paused;
}
fn parseScheduleState(value: []const u8) ScheduleState {
    inline for (std.meta.fields(ScheduleState)) |field| if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    return .unscheduled;
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

pub fn parseDuration(text: []const u8) !i64 {
    const input = std.mem.trim(u8, text, " \t\r\n");
    if (input.len == 0) return error.InvalidDuration;
    var index: usize = 0;
    var last_rank: u8 = 4;
    var total: i64 = 0;
    while (index < input.len) {
        while (index < input.len and std.ascii.isWhitespace(input[index])) index += 1;
        if (index == input.len) break;
        const start = index;
        while (index < input.len and std.ascii.isDigit(input[index])) index += 1;
        if (start == index or index == input.len) return error.InvalidDuration;
        const value = std.fmt.parseInt(i64, input[start..index], 10) catch return error.InvalidDuration;
        if (value <= 0) return error.InvalidDuration;
        const rank: u8, const multiplier: i64 = switch (input[index]) {
            'h' => .{ 3, 3_600_000 },
            'm' => .{ 2, 60_000 },
            's' => .{ 1, 1_000 },
            else => return error.InvalidDuration,
        };
        index += 1;
        if (rank >= last_rank) return error.InvalidDuration;
        last_rank = rank;
        total = std.math.add(i64, total, std.math.mul(i64, value, multiplier) catch return error.InvalidDuration) catch return error.InvalidDuration;
        if (index < input.len and !std.ascii.isWhitespace(input[index])) return error.InvalidDuration;
    }
    if (total <= 0) return error.InvalidDuration;
    return total;
}

pub fn parseRfc3339(text: []const u8) !i64 {
    const input = std.mem.trim(u8, text, " \t\r\n");
    if (input.len < 19 or input[4] != '-' or input[7] != '-' or input[10] != 'T' or input[13] != ':' or input[16] != ':') return error.InvalidRfc3339;
    const year = try digits(input, 0, 4);
    const month = try digits(input, 5, 2);
    const day = try digits(input, 8, 2);
    const hour = try digits(input, 11, 2);
    const minute = try digits(input, 14, 2);
    const second = try digits(input, 17, 2);
    if (year == 0 or month < 1 or month > 12 or day < 1 or day > monthDays(year, month) or hour > 23 or minute > 59 or second > 59) return error.InvalidRfc3339;
    var index: usize = 19;
    var millis: i64 = 0;
    if (index < input.len and input[index] == '.') {
        index += 1;
        const start = index;
        var count: usize = 0;
        while (index < input.len and std.ascii.isDigit(input[index])) : (index += 1) {
            if (count < 3) millis = millis * 10 + @as(i64, input[index] - '0');
            count += 1;
        }
        if (start == index) return error.InvalidRfc3339;
        while (count < 3) : (count += 1) millis *= 10;
    }
    var offset: i64 = 0;
    if (index < input.len and input[index] == 'Z') {
        index += 1;
    } else {
        if (index + 6 != input.len or (input[index] != '+' and input[index] != '-') or input[index + 3] != ':') return error.InvalidRfc3339;
        const sign: i64 = if (input[index] == '+') 1 else -1;
        const oh = try digits(input, index + 1, 2);
        const om = try digits(input, index + 4, 2);
        if (oh > 23 or om > 59) return error.InvalidRfc3339;
        offset = sign * @as(i64, @intCast(oh * 60 + om));
        index += 6;
    }
    if (index != input.len) return error.InvalidRfc3339;
    const days = daysFromCivil(@intCast(year), @intCast(month), @intCast(day));
    const seconds_total: i128 = @as(i128, days) * 86_400 + @as(i128, hour) * 3_600 + @as(i128, minute) * 60 + second - @as(i128, offset) * 60;
    return @intCast(seconds_total * 1_000 + millis);
}
fn digits(input: []const u8, start: usize, len: usize) !u32 {
    if (start + len > input.len) return error.InvalidRfc3339;
    for (input[start .. start + len]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidRfc3339;
    return std.fmt.parseInt(u32, input[start .. start + len], 10) catch error.InvalidRfc3339;
}
fn monthDays(year: u32, month: u32) u32 {
    return switch (month) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}
fn daysFromCivil(year_input: i64, month: i64, day: i64) i64 {
    var year = year_input;
    if (month <= 2) year -= 1;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const adjusted = month + (if (month > 2) @as(i64, -3) else 9);
    const doy = @divFloor(153 * adjusted + 2, 5) + day - 1;
    return era * 146097 + yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy - 719468;
}

test "parse scheduled snapshot" {
    const snapshot = try parseSnapshot(
        \\{"schema_version":2,"revision":2,"now_ms":100,"selected_project_id":1,"projects":[{"id":1,"name":"Core","created_at_ms":10,"updated_at_ms":11}],"timers":[{"id":7,"project_id":1,"label":"Plan","details":"Outcome","duration_ms":1500000,"status":"running","schedule_state":"consumed","accumulated_ms":100,"started_at_ms":20,"scheduled_start_ms":50,"planned_end_ms":1500050,"schedule_consumed_at_ms":60,"notification_claimed_at_ms":55,"created_at_ms":12,"updated_at_ms":13,"elapsed_ms":120,"remaining_ms":1499880,"overdue_ms":0,"scheduled_start_local":"2026-07-21 10:00:00 +0530","planned_end_local":"2026-07-21 10:25:00 +0530"}]}
    );
    try std.testing.expectEqual(@as(i64, 2), snapshot.schema_version);
    try std.testing.expectEqual(Status.running, snapshot.timers[0].status);
    try std.testing.expectEqual(ScheduleState.consumed, snapshot.timers[0].schedule_state);
    try std.testing.expectEqualStrings("Outcome", snapshot.timers[0].details());
}

test "form parsers validate duration and explicit schedule offsets" {
    try std.testing.expectEqual(@as(i64, 5_400_000), try parseDuration("1h 30m"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("30m 1h"));
    try std.testing.expectEqual(@as(i64, 0), try parseRfc3339("1970-01-01T05:30:00+05:30"));
    try std.testing.expectError(error.InvalidRfc3339, parseRfc3339("2026-07-21T10:00:00"));
}
