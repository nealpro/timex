const std = @import("std");
const store_mod = @import("store.zig");

const UsageError = error{Usage};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);

    run(init, &stdout_writer.interface) catch |err| {
        try stderr_writer.interface.print("timex-store: {s}\n", .{@errorName(err)});
        try stderr_writer.interface.flush();
        if (err == UsageError.Usage) {
            try printUsage(&stderr_writer.interface);
            try stderr_writer.interface.flush();
        }
        std.process.exit(1);
    };
}

fn run(init: std.process.Init, out: *std.Io.Writer) !void {
    var args_storage: [32][]const u8 = undefined;
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
        return writeSnapshot(init.io, out, try store.load());
    } else if (std.mem.eql(u8, command, "project-create")) {
        _ = try store.createProject(try requiredArg(args, "--name"), now);
    } else if (std.mem.eql(u8, command, "project-select")) {
        try store.setSelectedProject(try parseRequiredInt(args, "--project-id"));
    } else if (std.mem.eql(u8, command, "timer-create")) {
        _ = try store.createTimer(try parseRequiredInt(args, "--project-id"), try requiredArg(args, "--label"), now);
    } else if (std.mem.eql(u8, command, "timer-start")) {
        try store.startTimer(try parseRequiredInt(args, "--timer-id"), now);
    } else if (std.mem.eql(u8, command, "timer-pause")) {
        try store.pauseTimer(try parseRequiredInt(args, "--timer-id"), now);
    } else if (std.mem.eql(u8, command, "timer-delete")) {
        try store.deleteTimer(try parseRequiredInt(args, "--timer-id"));
    } else {
        return UsageError.Usage;
    }

    try writeSnapshot(init.io, out, try store.load());
}

fn writeSnapshot(io: std.Io, out: *std.Io.Writer, snapshot: store_mod.Snapshot) !void {
    const now = nowMs(io);
    try out.print("{{\"revision\":{d},\"selected_project_id\":{d},\"projects\":[", .{ snapshot.revision, snapshot.selected_project_id });
    for (snapshot.projects[0..snapshot.project_count], 0..) |*project, index| {
        if (index != 0) try out.writeAll(",");
        try out.print("{{\"id\":{d},\"name\":", .{project.id});
        try writeJsonString(out, project.name());
        try out.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d}}}", .{ project.created_at_ms, project.updated_at_ms });
    }
    try out.writeAll("],\"timers\":[");
    for (snapshot.timers[0..snapshot.timer_count], 0..) |*timer, index| {
        if (index != 0) try out.writeAll(",");
        try out.print("{{\"id\":{d},\"project_id\":{d},\"label\":", .{ timer.id, timer.project_id });
        try writeJsonString(out, timer.label());
        try out.print(",\"status\":\"{s}\",\"accumulated_ms\":{d},\"started_at_ms\":{d},\"created_at_ms\":{d},\"updated_at_ms\":{d},\"elapsed_ms\":{d}}}", .{
            @tagName(timer.status),
            timer.accumulated_ms,
            timer.started_at_ms,
            timer.created_at_ms,
            timer.updated_at_ms,
            timer.elapsedMs(now),
        });
    }
    try out.writeAll("]}\n");
    try out.flush();
}

fn argValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var index: usize = 2;
    while (index + 1 < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], name)) return args[index + 1];
    }
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
        \\  timex-store timer-create --db <path> --project-id <id> --label <label>
        \\  timex-store timer-start|timer-pause|timer-delete --db <path> --timer-id <id>
        \\
    );
}
