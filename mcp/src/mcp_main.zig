const std = @import("std");
const store_mod = @import("store.zig");

const Tool = struct { name: []const u8, description: []const u8, schema: []const u8 };

const tools = [_]Tool{
    .{ .name = "project_create", .description = "Create and select a Timex project.", .schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}" },
    .{ .name = "project_select", .description = "Select the active Timex project.", .schema = "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"integer\"}},\"required\":[\"project_id\"]}" },
    .{ .name = "timer_create", .description = "Create a labeled timer in a project.", .schema = "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"integer\"},\"label\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"label\"]}" },
    .{ .name = "timer_start", .description = "Start a paused timer.", .schema = "{\"type\":\"object\",\"properties\":{\"timer_id\":{\"type\":\"integer\"}},\"required\":[\"timer_id\"]}" },
    .{ .name = "timer_pause", .description = "Pause a running timer.", .schema = "{\"type\":\"object\",\"properties\":{\"timer_id\":{\"type\":\"integer\"}},\"required\":[\"timer_id\"]}" },
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
        const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch break;
        const request = std.mem.trim(u8, line, " \t\r\n");
        if (request.len == 0) continue;
        try handleRequest(allocator, init.io, &stdout_writer.interface, db_path, request);
    }
}

fn handleRequest(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, db_path: []const u8, request: []const u8) !void {
    _ = allocator;
    const id = rawField(request, "id") orelse "null";
    const method = stringField(request, "method") orelse return writeError(out, id, -32600, "missing method");
    if (std.mem.eql(u8, method, "initialize")) return writeInitialize(out, id);
    if (std.mem.eql(u8, method, "tools/list")) return writeTools(out, id);
    if (std.mem.eql(u8, method, "resources/list")) return writeResources(out, id);
    if (std.mem.eql(u8, method, "resources/read")) return readResource(io, out, id, db_path, request);
    if (std.mem.eql(u8, method, "tools/call")) return callTool(io, out, id, db_path, request);
    if (std.mem.eql(u8, method, "notifications/initialized")) return;
    return writeError(out, id, -32601, "method not found");
}

fn writeInitialize(out: *std.Io.Writer, id: []const u8) !void {
    try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{{\"tools\":{{}},\"resources\":{{}}}},\"serverInfo\":{{\"name\":\"timex\",\"version\":\"0.1.0\"}}}}}}\n", .{id});
    try out.flush();
}

fn writeTools(out: *std.Io.Writer, id: []const u8) !void {
    try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"tools\":[", .{id});
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

fn writeResources(out: *std.Io.Writer, id: []const u8) !void {
    try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"resources\":[", .{id});
    const entries = [_]struct { uri: []const u8, name: []const u8, description: []const u8 }{
        .{ .uri = "timex://current-view", .name = "Current Timex view", .description = "Selected project and visible timers." },
        .{ .uri = "timex://projects", .name = "Timex projects", .description = "All projects." },
        .{ .uri = "timex://state-summary", .name = "Timex state summary", .description = "Compact project/timer summary." },
    };
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

fn readResource(io: std.Io, out: *std.Io.Writer, id: []const u8, db_path: []const u8, request: []const u8) !void {
    const params = rawField(request, "params") orelse "{}";
    const uri = stringField(params, "uri") orelse return writeError(out, id, -32602, "missing uri");
    var store = store_mod.Store.open(db_path) catch return writeError(out, id, -32000, "database unavailable");
    defer store.close();
    const snapshot = store.load() catch return writeError(out, id, -32000, "load failed");

    try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"contents\":[{{\"uri\":", .{id});
    try writeJsonString(out, uri);
    try out.writeAll(",\"mimeType\":\"application/json\",\"text\":");
    try writeJsonString(out, try stateJson(io, snapshot, uri));
    try out.writeAll("}]}}\n");
    try out.flush();
}

fn stateJson(io: std.Io, snapshot: store_mod.Snapshot, uri: []const u8) ![]const u8 {
    var buffer: [24 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
    try writer.print("{{\"uri\":\"{s}\",\"revision\":{d},\"selected_project_id\":{d},\"projects\":[", .{ uri, snapshot.revision, snapshot.selected_project_id });
    for (snapshot.projects[0..snapshot.project_count], 0..) |*project, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"id\":{d},\"name\":", .{project.id});
        try writeJsonString(&writer, project.name());
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"timers\":[");
    for (snapshot.timers[0..snapshot.timer_count], 0..) |*timer, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"id\":{d},\"project_id\":{d},\"label\":", .{ timer.id, timer.project_id });
        try writeJsonString(&writer, timer.label());
        try writer.print(",\"status\":\"{s}\",\"elapsed_ms\":{d}}}", .{ @tagName(timer.status), timer.elapsedMs(now) });
    }
    try writer.writeAll("]}");
    return writer.buffered();
}

fn callTool(io: std.Io, out: *std.Io.Writer, id: []const u8, db_path: []const u8, request: []const u8) !void {
    const params = rawField(request, "params") orelse "{}";
    const name = stringField(params, "name") orelse return writeError(out, id, -32602, "missing tool name");
    const args = rawField(params, "arguments") orelse "{}";

    if (std.mem.eql(u8, name, "ui_snapshot")) return toolText(out, id, readFileText(io, ".zig-cache/native-sdk-automation/accessibility.txt"));
    if (std.mem.eql(u8, name, "ui_command")) {
        const command = stringField(args, "command") orelse return writeError(out, id, -32602, "missing command");
        queueAutomationCommand(io, command) catch return writeError(out, id, -32000, "failed to queue command");
        return toolText(out, id, "queued");
    }

    var store = store_mod.Store.open(db_path) catch return writeError(out, id, -32000, "database unavailable");
    defer store.close();
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
    if (std.mem.eql(u8, name, "project_create")) {
        const value = stringField(args, "name") orelse return writeError(out, id, -32602, "missing name");
        const project_id = store.createProject(value, now) catch return writeError(out, id, -32000, "project create failed");
        var buffer: [80]u8 = undefined;
        return toolText(out, id, std.fmt.bufPrint(&buffer, "created project {d}", .{project_id}) catch "created");
    }
    if (std.mem.eql(u8, name, "project_select")) {
        try store.setSelectedProject(intField(args, "project_id") orelse return writeError(out, id, -32602, "missing project_id"));
        return toolText(out, id, "selected");
    }
    if (std.mem.eql(u8, name, "timer_create")) {
        const project_id = intField(args, "project_id") orelse return writeError(out, id, -32602, "missing project_id");
        const label = stringField(args, "label") orelse return writeError(out, id, -32602, "missing label");
        const timer_id = store.createTimer(project_id, label, now) catch return writeError(out, id, -32000, "timer create failed");
        var buffer: [80]u8 = undefined;
        return toolText(out, id, std.fmt.bufPrint(&buffer, "created timer {d}", .{timer_id}) catch "created");
    }
    if (std.mem.eql(u8, name, "timer_start")) {
        try store.startTimer(intField(args, "timer_id") orelse return writeError(out, id, -32602, "missing timer_id"), now);
        return toolText(out, id, "started");
    }
    if (std.mem.eql(u8, name, "timer_pause")) {
        try store.pauseTimer(intField(args, "timer_id") orelse return writeError(out, id, -32602, "missing timer_id"), now);
        return toolText(out, id, "paused");
    }
    if (std.mem.eql(u8, name, "timer_delete")) {
        try store.deleteTimer(intField(args, "timer_id") orelse return writeError(out, id, -32602, "missing timer_id"));
        return toolText(out, id, "deleted");
    }
    return writeError(out, id, -32602, "unknown tool");
}

fn toolText(out: *std.Io.Writer, id: []const u8, text: []const u8) !void {
    try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":", .{id});
    try writeJsonString(out, text);
    try out.writeAll("}]}}\n");
    try out.flush();
}

fn writeError(out: *std.Io.Writer, id: []const u8, code: i32, message: []const u8) !void {
    try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":", .{ id, code });
    try writeJsonString(out, message);
    try out.writeAll("}}\n");
    try out.flush();
}

fn rawField(payload: []const u8, field: []const u8) ?[]const u8 {
    var index: usize = 0;
    skipWhitespace(payload, &index);
    if (index >= payload.len or payload[index] != '{') return null;
    index += 1;
    while (index < payload.len) {
        skipWhitespace(payload, &index);
        if (index < payload.len and payload[index] == '}') return null;
        const key = parseStringSpan(payload, &index) orelse return null;
        skipWhitespace(payload, &index);
        if (index >= payload.len or payload[index] != ':') return null;
        index += 1;
        skipWhitespace(payload, &index);
        const start = index;
        skipValue(payload, &index) orelse return null;
        const value = payload[start..index];
        if (std.mem.eql(u8, key, field)) return value;
        skipWhitespace(payload, &index);
        if (index < payload.len and payload[index] == ',') {
            index += 1;
            continue;
        }
        if (index < payload.len and payload[index] == '}') return null;
        return null;
    }
    return null;
}

fn stringField(payload: []const u8, field: []const u8) ?[]const u8 {
    var buffer: [1024]u8 = undefined;
    const raw = rawField(payload, field) orelse return null;
    return parseStringValue(raw, &buffer) catch null;
}

fn intField(payload: []const u8, field: []const u8) ?i64 {
    const raw = rawField(payload, field) orelse return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
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

fn readFileText(io: std.Io, path: []const u8) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(512 * 1024)) catch "automation snapshot unavailable";
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

fn skipWhitespace(bytes: []const u8, index: *usize) void {
    while (index.* < bytes.len and switch (bytes[index.*]) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    }) index.* += 1;
}

fn parseStringSpan(bytes: []const u8, index: *usize) ?[]const u8 {
    if (index.* >= bytes.len or bytes[index.*] != '"') return null;
    index.* += 1;
    const start = index.*;
    while (index.* < bytes.len) : (index.* += 1) {
        if (bytes[index.*] == '\\') {
            index.* += 1;
            continue;
        }
        if (bytes[index.*] == '"') {
            const out = bytes[start..index.*];
            index.* += 1;
            return out;
        }
    }
    return null;
}

fn parseStringValue(raw: []const u8, output: []u8) ![]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.InvalidJson;
    var input: usize = 1;
    var out: usize = 0;
    while (input + 1 < raw.len) : (input += 1) {
        var byte = raw[input];
        if (byte == '\\') {
            input += 1;
            if (input + 1 >= raw.len) return error.InvalidJson;
            byte = switch (raw[input]) {
                '"', '\\', '/' => raw[input],
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return error.InvalidJson,
            };
        }
        if (out >= output.len) return error.NoSpaceLeft;
        output[out] = byte;
        out += 1;
    }
    return output[0..out];
}

fn skipValue(bytes: []const u8, index: *usize) ?void {
    skipWhitespace(bytes, index);
    if (index.* >= bytes.len) return null;
    switch (bytes[index.*]) {
        '"' => _ = parseStringSpan(bytes, index) orelse return null,
        '{' => {
            index.* += 1;
            skipWhitespace(bytes, index);
            if (index.* < bytes.len and bytes[index.*] == '}') {
                index.* += 1;
                return;
            }
            while (index.* < bytes.len) {
                _ = parseStringSpan(bytes, index) orelse return null;
                skipWhitespace(bytes, index);
                if (index.* >= bytes.len or bytes[index.*] != ':') return null;
                index.* += 1;
                skipValue(bytes, index) orelse return null;
                skipWhitespace(bytes, index);
                if (index.* < bytes.len and bytes[index.*] == ',') {
                    index.* += 1;
                    continue;
                }
                if (index.* < bytes.len and bytes[index.*] == '}') {
                    index.* += 1;
                    return;
                }
                return null;
            }
        },
        '[' => {
            index.* += 1;
            while (index.* < bytes.len) {
                skipWhitespace(bytes, index);
                if (index.* < bytes.len and bytes[index.*] == ']') {
                    index.* += 1;
                    return;
                }
                skipValue(bytes, index) orelse return null;
                skipWhitespace(bytes, index);
                if (index.* < bytes.len and bytes[index.*] == ',') index.* += 1;
            }
            return null;
        },
        else => {
            while (index.* < bytes.len and !std.mem.containsAtLeastScalar(u8, " \t\r\n,}]", 1, bytes[index.*])) index.* += 1;
        },
    }
}
