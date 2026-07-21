const std = @import("std");
const store_mod = @import("store.zig");

const Tool = struct { name: []const u8, description: []const u8, schema: []const u8 };

const tools = [_]Tool{
    .{ .name = "project_create", .description = "Create and select a Timex project.", .schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}" },
    .{ .name = "project_select", .description = "Select the active Timex project.", .schema = "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"integer\"}},\"required\":[\"project_id\"]}" },
    .{ .name = "timer_create", .description = "Create a paused time-boxed task, optionally scheduled at an RFC 3339 instant with an explicit offset.", .schema = "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"integer\"},\"label\":{\"type\":\"string\"},\"duration\":{\"type\":\"string\",\"description\":\"Examples: 25m, 1h, 1h 30m\"},\"details\":{\"type\":\"string\",\"maxLength\":512},\"scheduled_start\":{\"type\":\"string\",\"description\":\"RFC 3339 with explicit offset\"}},\"required\":[\"project_id\",\"label\",\"duration\"]}" },
    .{ .name = "timer_start", .description = "Start a paused timer and consume any pending calendar start.", .schema = "{\"type\":\"object\",\"properties\":{\"timer_id\":{\"type\":\"integer\"}},\"required\":[\"timer_id\"]}" },
    .{ .name = "timer_pause", .description = "Pause a running timer.", .schema = "{\"type\":\"object\",\"properties\":{\"timer_id\":{\"type\":\"integer\"}},\"required\":[\"timer_id\"]}" },
    .{ .name = "timer_reset", .description = "Reset elapsed time to zero and pause without requeuing a consumed schedule.", .schema = "{\"type\":\"object\",\"properties\":{\"timer_id\":{\"type\":\"integer\"}},\"required\":[\"timer_id\"]}" },
    .{ .name = "timer_delete", .description = "Delete a timer.", .schema = "{\"type\":\"object\",\"properties\":{\"timer_id\":{\"type\":\"integer\"}},\"required\":[\"timer_id\"]}" },
    .{ .name = "ui_snapshot", .description = "Read Native automation accessibility snapshot text if the app is running with automation enabled.", .schema = "{\"type\":\"object\",\"properties\":{}}" },
    .{ .name = "ui_command", .description = "Queue a raw Native automation command for the running app.", .schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}" },
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var db_path_buffer: [store_mod.max_path_bytes]u8 = undefined;
    const db_path = resolveDbPath(init, &db_path_buffer) orelse ".zig-cache/timex.sqlite";
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    while (true) {
        const line = (stdin_reader.interface.takeDelimiter('\n') catch break) orelse break;
        const request = std.mem.trim(u8, line, " \t\r\n");
        if (request.len != 0) try handleRequest(allocator, init.io, &stdout_writer.interface, db_path, request);
    }
}

fn handleRequest(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, db_path: []const u8, request: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request, .{}) catch return writeError(out, .null, -32700, "parse error");
    defer parsed.deinit();
    const root = parsed.value;
    const id = jsonField(root, "id") orelse .null;
    const method = jsonStringField(root, "method") orelse return writeError(out, id, -32600, "missing method");
    if (std.mem.eql(u8, method, "initialize")) return writeInitialize(out, id);
    if (std.mem.eql(u8, method, "tools/list")) return writeTools(out, id);
    if (std.mem.eql(u8, method, "resources/list")) return writeResources(out, id);
    if (std.mem.eql(u8, method, "resources/templates/list")) return writeResourceTemplates(out, id);
    if (std.mem.eql(u8, method, "resources/read")) return readResource(io, out, id, db_path, root);
    if (std.mem.eql(u8, method, "tools/call")) return callTool(io, out, id, db_path, root);
    if (std.mem.eql(u8, method, "notifications/initialized")) return;
    return writeError(out, id, -32601, "method not found");
}

fn writeInitialize(out: *std.Io.Writer, id: std.json.Value) !void {
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(out, id);
    try out.writeAll(",\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{},\"resources\":{}},\"serverInfo\":{\"name\":\"timex\",\"version\":\"0.2.0\"}}}\n");
    try out.flush();
}

fn writeTools(out: *std.Io.Writer, id: std.json.Value) !void {
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(out, id);
    try out.writeAll(",\"result\":{\"tools\":[");
    for (tools, 0..) |tool, index| {
        if (index != 0) try out.writeAll(",");
        try out.writeAll("{\"name\":");
        try writeJsonString(out, tool.name);
        try out.writeAll(",\"description\":");
        try writeJsonString(out, tool.description);
        try out.print(",\"inputSchema\":{s}}}", .{tool.schema});
    }
    try out.writeAll("]}}\n");
    try out.flush();
}

fn writeResources(out: *std.Io.Writer, id: std.json.Value) !void {
    const entries = [_]struct { uri: []const u8, name: []const u8, description: []const u8 }{
        .{ .uri = "timex://current-view", .name = "Current Timex view", .description = "Selected project and its visible scheduled timers." },
        .{ .uri = "timex://projects", .name = "Timex projects", .description = "All Timex projects and their tasks." },
        .{ .uri = "timex://state-summary", .name = "Timex state summary", .description = "All projects, time boxes, schedule states, and countdowns." },
    };
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(out, id);
    try out.writeAll(",\"result\":{\"resources\":[");
    for (entries, 0..) |entry, index| {
        if (index != 0) try out.writeAll(",");
        try out.writeAll("{\"uri\":");
        try writeJsonString(out, entry.uri);
        try out.writeAll(",\"name\":");
        try writeJsonString(out, entry.name);
        try out.writeAll(",\"description\":");
        try writeJsonString(out, entry.description);
        try out.writeAll(",\"mimeType\":\"application/json\"}");
    }
    try out.writeAll("]}}\n");
    try out.flush();
}

fn writeResourceTemplates(out: *std.Io.Writer, id: std.json.Value) !void {
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(out, id);
    try out.writeAll(",\"result\":{\"resourceTemplates\":[]}}\n");
    try out.flush();
}

fn readResource(io: std.Io, out: *std.Io.Writer, id: std.json.Value, db_path: []const u8, request: std.json.Value) !void {
    const params = jsonField(request, "params") orelse .null;
    const uri = jsonStringField(params, "uri") orelse return writeError(out, id, -32602, "missing uri");
    if (!std.mem.eql(u8, uri, "timex://current-view") and !std.mem.eql(u8, uri, "timex://projects") and !std.mem.eql(u8, uri, "timex://state-summary")) return writeError(out, id, -32602, "unknown uri");
    var store = store_mod.Store.open(db_path) catch return writeError(out, id, -32000, "database unavailable");
    defer store.close();
    const snapshot = store.loadAll() catch return writeError(out, id, -32000, "load failed");
    var state_buffer: [128 * 1024]u8 = undefined;
    const state = stateJson(io, snapshot, uri, &state_buffer) catch return writeError(out, id, -32000, "state serialization failed");
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(out, id);
    try out.writeAll(",\"result\":{\"contents\":[{\"uri\":");
    try writeJsonString(out, uri);
    try out.writeAll(",\"mimeType\":\"application/json\",\"text\":");
    try writeJsonString(out, state);
    try out.writeAll("}]}}\n");
    try out.flush();
}

fn stateJson(io: std.Io, snapshot: store_mod.Snapshot, uri: []const u8, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    const now = nowMs(io);
    try writer.writeAll("{\"uri\":");
    try writeJsonString(&writer, uri);
    try writer.print(",\"schema_version\":{d},\"revision\":{d},\"now_ms\":{d},\"selected_project_id\":{d},\"projects\":[", .{ snapshot.schema, snapshot.revision, now, snapshot.selected_project_id });
    for (snapshot.projects[0..snapshot.project_count], 0..) |*project, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"id\":{d},\"name\":", .{project.id});
        try writeJsonString(&writer, project.name());
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"timers\":[");
    var written: usize = 0;
    for (snapshot.timers[0..snapshot.timer_count]) |*timer| {
        if (std.mem.eql(u8, uri, "timex://current-view") and timer.project_id != snapshot.selected_project_id) continue;
        if (written != 0) try writer.writeAll(",");
        try writeTimerJson(&writer, timer, now);
        written += 1;
    }
    try writer.writeAll("]}");
    return writer.buffered();
}

fn writeTimerJson(out: *std.Io.Writer, timer: *const store_mod.Timer, now: i64) !void {
    const remaining = timer.remainingMs(now);
    try out.print("{{\"id\":{d},\"project_id\":{d},\"label\":", .{ timer.id, timer.project_id });
    try writeJsonString(out, timer.label());
    try out.writeAll(",\"details\":");
    if (timer.details().len == 0) try out.writeAll("null") else try writeJsonString(out, timer.details());
    try out.print(",\"duration_ms\":{d},\"status\":\"{s}\",\"accumulated_ms\":{d},\"started_at_ms\":{d},\"elapsed_ms\":{d},\"remaining_ms\":{d},\"overdue_ms\":{d},\"scheduled_start_ms\":", .{
        timer.duration_ms, @tagName(timer.status), timer.accumulated_ms, timer.started_at_ms, timer.elapsedMs(now), remaining, timer.overdueMs(now),
    });
    if (timer.scheduled_start_ms == 0) try out.writeAll("null") else try out.print("{d}", .{timer.scheduled_start_ms});
    try out.writeAll(",\"planned_end_ms\":");
    if (timer.plannedEndMs() == 0) try out.writeAll("null") else try out.print("{d}", .{timer.plannedEndMs()});
    try out.print(",\"schedule_state\":\"{s}\",\"schedule_delay_ms\":{d},\"schedule_consumed_at_ms\":", .{ @tagName(timer.scheduleState(now)), timer.scheduleDelayMs() });
    if (timer.schedule_consumed_at_ms == 0) try out.writeAll("null") else try out.print("{d}", .{timer.schedule_consumed_at_ms});
    try out.writeAll(",\"notification_claimed_at_ms\":");
    if (timer.notification_claimed_at_ms == 0) try out.writeAll("null") else try out.print("{d}", .{timer.notification_claimed_at_ms});
    try out.writeAll("}");
}

fn callTool(io: std.Io, out: *std.Io.Writer, id: std.json.Value, db_path: []const u8, request: std.json.Value) !void {
    const params = jsonField(request, "params") orelse .null;
    const name = jsonStringField(params, "name") orelse return writeError(out, id, -32602, "missing tool name");
    const args = jsonField(params, "arguments") orelse .null;
    if (std.mem.eql(u8, name, "ui_snapshot")) {
        const snapshot = readFileText(io, ".zig-cache/native-sdk-automation/accessibility.txt") orelse return toolText(out, id, "automation snapshot unavailable");
        defer std.heap.page_allocator.free(snapshot);
        return toolText(out, id, snapshot);
    }
    if (std.mem.eql(u8, name, "ui_command")) {
        const command = jsonStringField(args, "command") orelse return writeError(out, id, -32602, "missing command");
        queueAutomationCommand(io, command) catch return writeError(out, id, -32000, "failed to queue command");
        return toolText(out, id, "queued");
    }

    var store = store_mod.Store.open(db_path) catch return writeError(out, id, -32000, "database unavailable");
    defer store.close();
    const now = nowMs(io);
    if (std.mem.eql(u8, name, "project_create")) {
        const value = jsonStringField(args, "name") orelse return writeError(out, id, -32602, "missing name");
        const project_id = store.createProject(value, now) catch |err| return writeError(out, id, -32602, @errorName(err));
        var buffer: [80]u8 = undefined;
        return toolText(out, id, std.fmt.bufPrint(&buffer, "created project {d}", .{project_id}) catch "created");
    }
    if (std.mem.eql(u8, name, "project_select")) {
        store.setSelectedProject(jsonIntField(args, "project_id") orelse return writeError(out, id, -32602, "missing project_id")) catch |err| return writeError(out, id, -32602, @errorName(err));
        return toolText(out, id, "selected");
    }
    if (std.mem.eql(u8, name, "timer_create")) {
        const project_id = jsonIntField(args, "project_id") orelse return writeError(out, id, -32602, "missing project_id");
        const label = jsonStringField(args, "label") orelse return writeError(out, id, -32602, "missing label");
        const duration_text = jsonStringField(args, "duration") orelse return writeError(out, id, -32602, "missing duration");
        const duration = store_mod.parseDuration(duration_text) catch |err| return writeError(out, id, -32602, @errorName(err));
        const details = jsonStringField(args, "details");
        const scheduled_start = if (jsonStringField(args, "scheduled_start")) |value| store_mod.parseRfc3339(value) catch |err| return writeError(out, id, -32602, @errorName(err)) else null;
        const timer_id = store.createTimer(project_id, label, duration, details, scheduled_start, now) catch |err| return writeError(out, id, -32602, @errorName(err));
        var buffer: [80]u8 = undefined;
        return toolText(out, id, std.fmt.bufPrint(&buffer, "created timer {d}", .{timer_id}) catch "created");
    }
    const timer_id = jsonIntField(args, "timer_id") orelse return writeError(out, id, -32602, "missing timer_id");
    if (std.mem.eql(u8, name, "timer_start")) {
        store.startTimer(timer_id, now) catch |err| return writeError(out, id, -32602, @errorName(err));
        return toolText(out, id, "started");
    }
    if (std.mem.eql(u8, name, "timer_pause")) {
        store.pauseTimer(timer_id, now) catch |err| return writeError(out, id, -32602, @errorName(err));
        return toolText(out, id, "paused");
    }
    if (std.mem.eql(u8, name, "timer_reset")) {
        store.resetTimer(timer_id, now) catch |err| return writeError(out, id, -32602, @errorName(err));
        return toolText(out, id, "reset");
    }
    if (std.mem.eql(u8, name, "timer_delete")) {
        store.deleteTimer(timer_id) catch |err| return writeError(out, id, -32602, @errorName(err));
        return toolText(out, id, "deleted");
    }
    return writeError(out, id, -32602, "unknown tool");
}

fn toolText(out: *std.Io.Writer, id: std.json.Value, value: []const u8) !void {
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(out, id);
    try out.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(out, value);
    try out.writeAll("}]}}\n");
    try out.flush();
}

fn writeError(out: *std.Io.Writer, id: std.json.Value, code: i32, message: []const u8) !void {
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(out, id);
    try out.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try writeJsonString(out, message);
    try out.writeAll("}}\n");
    try out.flush();
}

fn jsonField(value: std.json.Value, field: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(field),
        else => null,
    };
}
fn jsonStringField(value: std.json.Value, field: []const u8) ?[]const u8 {
    const member = jsonField(value, field) orelse return null;
    return switch (member) {
        .string => |string| string,
        else => null,
    };
}
fn jsonIntField(value: std.json.Value, field: []const u8) ?i64 {
    const member = jsonField(value, field) orelse return null;
    return switch (member) {
        .integer => |integer| integer,
        else => null,
    };
}
fn writeJsonValue(out: *std.Io.Writer, value: std.json.Value) !void {
    try std.json.Stringify.value(value, .{}, out);
}
fn writeJsonString(out: *std.Io.Writer, value: []const u8) !void {
    try out.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        else => if (byte < 0x20) try out.print("\\u{x:0>4}", .{byte}) else try out.writeByte(byte),
    };
    try out.writeByte('"');
}
fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
}
fn readFileText(io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(512 * 1024)) catch null;
}
fn queueAutomationCommand(io: std.Io, command: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, ".zig-cache/native-sdk-automation", .{});
    defer dir.close(io);
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "command-{d}.txt", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    var line_buffer: [16 * 1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buffer, "{s}\n", .{command});
    try dir.writeFile(io, .{ .sub_path = name, .data = line });
}
fn resolveDbPath(init: std.process.Init, output: []u8) ?[]const u8 {
    if (init.environ_map.get("TIMEX_DB_PATH")) |override| return copyPath(output, override);
    if (init.environ_map.get("HOME")) |home| {
        const path = std.fmt.bufPrint(output, "{s}/Library/Application Support/timex/timex.sqlite", .{home}) catch return copyPath(output, ".zig-cache/timex.sqlite");
        const dir = std.fs.path.dirname(path) orelse return path;
        makePath(init.io, dir) catch {};
        return path;
    }
    makePath(init.io, ".zig-cache") catch {};
    return copyPath(output, ".zig-cache/timex.sqlite");
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

fn testRequest(output: []u8, db_path: []const u8, request: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    try handleRequest(std.testing.allocator, std.testing.io, &writer, db_path, request);
    return writer.buffered();
}
fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "MCP protocol discovery exposes scheduling tools and resources" {
    var output: [128 * 1024]u8 = undefined;
    try expectContains(try testRequest(&output, ".zig-cache/timex-test-unused.sqlite", "{\"params\":{},\"method\":\"initialize\",\"id\":\"init-\\u0031\",\"jsonrpc\":\"2.0\"}"), "\"version\":\"0.2.0\"");
    const listed = try testRequest(&output, ".zig-cache/timex-test-unused.sqlite", "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}");
    try expectContains(listed, "\"name\":\"timer_reset\"");
    try expectContains(listed, "\"duration\"");
    try expectContains(try testRequest(&output, ".zig-cache/timex-test-unused.sqlite", "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/list\",\"params\":{}}"), "timex://state-summary");
    try expectContains(try testRequest(&output, ".zig-cache/timex-test-unused.sqlite", "{not json}"), "\"code\":-32700");
}

test "MCP semantic scheduling workflow uses a disposable store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db_path_buffer: [256]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&db_path_buffer, ".zig-cache/tmp/{s}/timex.sqlite", .{tmp.sub_path});
    var output: [128 * 1024]u8 = undefined;
    try expectContains(try testRequest(&output, db_path, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"project_create\",\"arguments\":{\"name\":\"Codex \\u2603\"}}}"), "created project 1");
    const created = try testRequest(&output, db_path, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"timer_create\",\"arguments\":{\"project_id\":1,\"label\":\"MCP smoke test\",\"duration\":\"25m\",\"details\":\"Produce a verified result\"}}}");
    try expectContains(created, "created timer 1");
    try expectContains(try testRequest(&output, db_path, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"timer_start\",\"arguments\":{\"timer_id\":1}}}"), "started");
    try expectContains(try testRequest(&output, db_path, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"timer_reset\",\"arguments\":{\"timer_id\":1}}}"), "reset");
    const state = try testRequest(&output, db_path, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/read\",\"params\":{\"uri\":\"timex://state-summary\"}}");
    try expectContains(state, "MCP smoke test");
    try expectContains(state, "\\\"duration_ms\\\":1500000");
    try expectContains(state, "Produce a verified result");
    const invalid = try testRequest(&output, db_path, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"timer_create\",\"arguments\":{\"project_id\":1,\"label\":\"Bad\",\"duration\":\"0m\"}}}");
    try expectContains(invalid, "InvalidDuration");
}
