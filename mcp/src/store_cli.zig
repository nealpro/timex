const std = @import("std");
const store_mod = @import("store.zig");

const c = @cImport({
    @cInclude("time.h");
});

const UsageError = error{Usage};
const notification_script = "on run argv\ndisplay notification (item 1 of argv) with title \"Timex\"\nend run";

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [128 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    run(init, &stdout_writer.interface) catch |err| {
        try stderr_writer.interface.print("timex-store: {s}\n", .{@errorName(err)});
        if (err == UsageError.Usage) try printUsage(&stderr_writer.interface);
        try stderr_writer.interface.flush();
        std.process.exit(1);
    };
}

fn run(init: std.process.Init, out: *std.Io.Writer) !void {
    var args_storage: [48][]const u8 = undefined;
    var args_len: usize = 0;
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer iterator.deinit();
    while (iterator.next()) |arg| {
        if (args_len >= args_storage.len) return UsageError.Usage;
        args_storage[args_len] = arg;
        args_len += 1;
    }
    const args = args_storage[0..args_len];
    if (args.len < 2) return UsageError.Usage;
    const command = args[1];
    const db_path = argValue(args, "--db") orelse init.environ_map.get("TIMEX_DB_PATH") orelse ".zig-cache/timex.sqlite";
    const now = nowMs(init.io);
    var store = try store_mod.Store.open(db_path);
    defer store.close();

    if (std.mem.eql(u8, command, "snapshot")) {
        // The Native app calls this every second. Reconciliation is deliberately
        // confined to this helper rather than MCP resource reads.
    } else if (std.mem.eql(u8, command, "project-create")) {
        _ = try store.createProject(try requiredArg(args, "--name"), now);
    } else if (std.mem.eql(u8, command, "project-select")) {
        try store.setSelectedProject(try parseRequiredInt(args, "--project-id"));
    } else if (std.mem.eql(u8, command, "timer-create")) {
        const scheduled_start = if (argValue(args, "--scheduled-start")) |value| try store_mod.parseRfc3339(value) else null;
        _ = try store.createTimer(
            try parseRequiredInt(args, "--project-id"),
            try requiredArg(args, "--label"),
            try store_mod.parseDuration(try requiredArg(args, "--duration")),
            argValue(args, "--details"),
            scheduled_start,
            now,
        );
    } else if (std.mem.eql(u8, command, "timer-start")) {
        try store.startTimer(try parseRequiredInt(args, "--timer-id"), now);
    } else if (std.mem.eql(u8, command, "timer-pause")) {
        try store.pauseTimer(try parseRequiredInt(args, "--timer-id"), now);
    } else if (std.mem.eql(u8, command, "timer-reset")) {
        try store.resetTimer(try parseRequiredInt(args, "--timer-id"), now);
    } else if (std.mem.eql(u8, command, "timer-delete")) {
        try store.deleteTimer(try parseRequiredInt(args, "--timer-id"));
    } else {
        return UsageError.Usage;
    }

    const reconciliation = try store.reconcile(now);
    for (reconciliation.notifications[0..reconciliation.notification_count]) |*timer| {
        sendNotification(init, timer) catch {};
    }
    try writeSnapshot(out, try store.load(), now);
}

fn writeSnapshot(out: *std.Io.Writer, snapshot: store_mod.Snapshot, now: i64) !void {
    try out.print("{{\"schema_version\":{d},\"revision\":{d},\"now_ms\":{d},\"selected_project_id\":{d},\"projects\":[", .{ snapshot.schema, snapshot.revision, now, snapshot.selected_project_id });
    for (snapshot.projects[0..snapshot.project_count], 0..) |*project, index| {
        if (index != 0) try out.writeAll(",");
        try out.print("{{\"id\":{d},\"name\":", .{project.id});
        try writeJsonString(out, project.name());
        try out.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d}}}", .{ project.created_at_ms, project.updated_at_ms });
    }
    try out.writeAll("],\"timers\":[");
    for (snapshot.timers[0..snapshot.timer_count], 0..) |*timer, index| {
        if (index != 0) try out.writeAll(",");
        try writeTimerJson(out, timer, now);
    }
    try out.writeAll("]}\n");
    try out.flush();
}

fn writeTimerJson(out: *std.Io.Writer, timer: *const store_mod.Timer, now: i64) !void {
    try out.print("{{\"id\":{d},\"project_id\":{d},\"label\":", .{ timer.id, timer.project_id });
    try writeJsonString(out, timer.label());
    try out.writeAll(",\"details\":");
    if (timer.details().len == 0) try out.writeAll("null") else try writeJsonString(out, timer.details());
    try out.print(",\"duration_ms\":{d},\"status\":\"{s}\",\"accumulated_ms\":{d},\"started_at_ms\":{d},\"created_at_ms\":{d},\"updated_at_ms\":{d},\"elapsed_ms\":{d},\"remaining_ms\":{d},\"overdue_ms\":{d},\"schedule_state\":\"{s}\",\"schedule_delay_ms\":{d},\"scheduled_start_ms\":", .{
        timer.duration_ms,
        @tagName(timer.status),
        timer.accumulated_ms,
        timer.started_at_ms,
        timer.created_at_ms,
        timer.updated_at_ms,
        timer.elapsedMs(now),
        timer.remainingMs(now),
        timer.overdueMs(now),
        @tagName(timer.scheduleState(now)),
        timer.scheduleDelayMs(),
    });
    if (timer.scheduled_start_ms == 0) try out.writeAll("null") else try out.print("{d}", .{timer.scheduled_start_ms});
    try out.writeAll(",\"planned_end_ms\":");
    if (timer.plannedEndMs() == 0) try out.writeAll("null") else try out.print("{d}", .{timer.plannedEndMs()});
    try out.writeAll(",\"scheduled_start_local\":");
    try writeLocalTimeOrNull(out, timer.scheduled_start_ms);
    try out.writeAll(",\"planned_end_local\":");
    try writeLocalTimeOrNull(out, timer.plannedEndMs());
    try out.writeAll(",\"schedule_consumed_at_ms\":");
    if (timer.schedule_consumed_at_ms == 0) try out.writeAll("null") else try out.print("{d}", .{timer.schedule_consumed_at_ms});
    try out.writeAll(",\"notification_claimed_at_ms\":");
    if (timer.notification_claimed_at_ms == 0) try out.writeAll("null") else try out.print("{d}", .{timer.notification_claimed_at_ms});
    try out.writeAll("}");
}

fn writeLocalTimeOrNull(out: *std.Io.Writer, milliseconds: i64) !void {
    if (milliseconds == 0) return out.writeAll("null");
    var buffer: [64]u8 = undefined;
    const value = formatLocalTime(&buffer, milliseconds) orelse return out.writeAll("null");
    try writeJsonString(out, value);
}

fn formatLocalTime(output: []u8, milliseconds: i64) ?[]const u8 {
    var seconds: c.time_t = @intCast(@divFloor(milliseconds, 1_000));
    var local: c.struct_tm = undefined;
    if (c.localtime_r(&seconds, &local) == null) return null;
    const len = c.strftime(output.ptr, output.len, "%Y-%m-%d %H:%M:%S %z", &local);
    if (len == 0) return null;
    return output[0..len];
}

fn notificationMessage(output: []u8, timer: *const store_mod.Timer) ![]const u8 {
    return std.fmt.bufPrint(output, "{s} is ready", .{timer.label()});
}

fn sendNotification(init: std.process.Init, timer: *const store_mod.Timer) !void {
    if (@import("builtin").os.tag != .macos) return;
    var message_buffer: [store_mod.max_label_bytes + 32]u8 = undefined;
    const message = try notificationMessage(&message_buffer, timer);
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = &.{ "/usr/bin/osascript", "-e", notification_script, "--", message },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.NotificationFailed;
}

fn argValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var index: usize = 2;
    while (index + 1 < args.len) : (index += 1) if (std.mem.eql(u8, args[index], name)) return args[index + 1];
    return null;
}
fn requiredArg(args: []const []const u8, name: []const u8) ![]const u8 {
    return argValue(args, name) orelse UsageError.Usage;
}
fn parseRequiredInt(args: []const []const u8, name: []const u8) !i64 {
    return std.fmt.parseInt(i64, try requiredArg(args, name), 10);
}
fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
}
fn writeJsonString(out: *std.Io.Writer, text: []const u8) !void {
    try out.writeByte('"');
    for (text) |byte| switch (byte) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        else => if (byte < 0x20) try out.print("\\u{x:0>4}", .{byte}) else try out.writeByte(byte),
    };
    try out.writeByte('"');
}
fn printUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\usage:
        \\  timex-store snapshot --db <path>
        \\  timex-store project-create --db <path> --name <name>
        \\  timex-store project-select --db <path> --project-id <id>
        \\  timex-store timer-create --db <path> --project-id <id> --label <label> --duration <duration> [--details <text>] [--scheduled-start <rfc3339>]
        \\  timex-store timer-start|timer-pause|timer-reset|timer-delete --db <path> --timer-id <id>
        \\
    );
}

test "notification text remains a single safely argumentized value" {
    var timer = store_mod.Timer{};
    timer.setLabel("Review 'quoted' task; do shell script \"bad\"");
    var buffer: [256]u8 = undefined;
    const message = try notificationMessage(&buffer, &timer);
    try std.testing.expectEqualStrings("Review 'quoted' task; do shell script \"bad\" is ready", message);
    try std.testing.expect(std.mem.indexOf(u8, notification_script, message) == null);
}

test "local time formatter produces a system-zone display" {
    var buffer: [64]u8 = undefined;
    const value = formatLocalTime(&buffer, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(value.len >= 24);
}
