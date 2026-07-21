const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const schema_version: i64 = 2;
pub const max_projects = 48;
pub const max_timers = 128;
pub const max_name_bytes = 64;
pub const max_label_bytes = 96;
pub const max_details_bytes = 512;
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
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        const len = @min(trimmed.len, max_name_bytes);
        @memcpy(project.name_storage[0..len], trimmed[0..len]);
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
    duration_ms: i64 = 0,
    status: Status = .paused,
    accumulated_ms: i64 = 0,
    started_at_ms: i64 = 0,
    scheduled_start_ms: i64 = 0,
    schedule_consumed_at_ms: i64 = 0,
    notification_claimed_at_ms: i64 = 0,
    created_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,

    pub fn label(timer: *const Timer) []const u8 {
        return timer.label_storage[0..timer.label_len];
    }

    pub fn setLabel(timer: *Timer, value: []const u8) void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        const len = @min(trimmed.len, max_label_bytes);
        @memcpy(timer.label_storage[0..len], trimmed[0..len]);
        timer.label_len = len;
    }

    pub fn details(timer: *const Timer) []const u8 {
        return timer.details_storage[0..timer.details_len];
    }

    pub fn setDetails(timer: *Timer, value: []const u8) void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        const len = @min(trimmed.len, max_details_bytes);
        @memcpy(timer.details_storage[0..len], trimmed[0..len]);
        timer.details_len = len;
    }

    pub fn elapsedMs(timer: *const Timer, now_ms: i64) i64 {
        if (timer.status == .running and timer.started_at_ms > 0) {
            const active = @max(@as(i64, 0), std.math.sub(i64, now_ms, timer.started_at_ms) catch std.math.maxInt(i64));
            return std.math.add(i64, timer.accumulated_ms, active) catch std.math.maxInt(i64);
        }
        return timer.accumulated_ms;
    }

    pub fn remainingMs(timer: *const Timer, now_ms: i64) i64 {
        return std.math.sub(i64, timer.duration_ms, timer.elapsedMs(now_ms)) catch std.math.minInt(i64);
    }

    pub fn overdueMs(timer: *const Timer, now_ms: i64) i64 {
        const remaining = timer.remainingMs(now_ms);
        if (remaining >= 0) return 0;
        return std.math.sub(i64, 0, remaining) catch std.math.maxInt(i64);
    }

    pub fn plannedEndMs(timer: *const Timer) i64 {
        if (timer.scheduled_start_ms == 0) return 0;
        return std.math.add(i64, timer.scheduled_start_ms, timer.duration_ms) catch 0;
    }

    pub fn scheduleState(timer: *const Timer, now_ms: i64) ScheduleState {
        if (timer.scheduled_start_ms == 0) return .unscheduled;
        if (timer.schedule_consumed_at_ms != 0) return .consumed;
        if (timer.scheduled_start_ms > now_ms) return .upcoming;
        return .waiting;
    }

    pub fn scheduleDelayMs(timer: *const Timer) i64 {
        if (timer.scheduled_start_ms == 0 or timer.schedule_consumed_at_ms == 0) return 0;
        return std.math.sub(i64, timer.schedule_consumed_at_ms, timer.scheduled_start_ms) catch 0;
    }
};

pub const Snapshot = struct {
    projects: [max_projects]Project = undefined,
    project_count: usize = 0,
    timers: [max_timers]Timer = undefined,
    timer_count: usize = 0,
    selected_project_id: i64 = 0,
    revision: i64 = 0,
    schema: i64 = schema_version,
};

pub const ReconcileResult = struct {
    notifications: [max_timers]Timer = undefined,
    notification_count: usize = 0,
    started_timer_id: i64 = 0,
};

pub const Store = struct {
    db: ?*c.sqlite3 = null,

    pub fn open(path: []const u8) !Store {
        var db: ?*c.sqlite3 = null;
        const path_z = try std.heap.c_allocator.dupeZ(u8, path);
        defer std.heap.c_allocator.free(path_z);
        if (c.sqlite3_open(path_z.ptr, &db) != c.SQLITE_OK) return error.OpenFailed;
        var store = Store{ .db = db };
        errdefer store.close();
        try store.exec("PRAGMA journal_mode=WAL;");
        try store.exec("PRAGMA foreign_keys=ON;");
        try store.migrate();
        return store;
    }

    pub fn close(store: *Store) void {
        if (store.db) |db| _ = c.sqlite3_close(db);
        store.db = null;
    }

    pub fn exec(store: *Store, sql: [:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(store.db.?, sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            if (err_msg != null) c.sqlite3_free(err_msg);
            return error.SqliteExecFailed;
        }
    }

    fn migrate(store: *Store) !void {
        if (try store.pragmaUserVersion() == schema_version) return;
        try store.exec(
            \\BEGIN IMMEDIATE;
            \\DROP TABLE IF EXISTS timers;
            \\DROP TABLE IF EXISTS projects;
            \\DROP TABLE IF EXISTS meta;
            \\CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            \\CREATE TABLE projects(
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            \\  created_at_ms INTEGER NOT NULL,
            \\  updated_at_ms INTEGER NOT NULL
            \\);
            \\CREATE TABLE timers(
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            \\  label TEXT NOT NULL,
            \\  details TEXT,
            \\  duration_ms INTEGER NOT NULL CHECK(duration_ms > 0),
            \\  status TEXT NOT NULL CHECK(status IN ('paused','running')),
            \\  accumulated_ms INTEGER NOT NULL DEFAULT 0 CHECK(accumulated_ms >= 0),
            \\  started_at_ms INTEGER NOT NULL DEFAULT 0,
            \\  scheduled_start_ms INTEGER,
            \\  schedule_consumed_at_ms INTEGER,
            \\  notification_claimed_at_ms INTEGER,
            \\  created_at_ms INTEGER NOT NULL,
            \\  updated_at_ms INTEGER NOT NULL
            \\);
            \\CREATE INDEX timers_schedule_queue ON timers(schedule_consumed_at_ms, scheduled_start_ms, created_at_ms, id);
            \\INSERT INTO meta(key, value) VALUES('schema_version', '2');
            \\INSERT INTO meta(key, value) VALUES('revision', '0');
            \\INSERT INTO meta(key, value) VALUES('last_selected_project_id', '0');
            \\PRAGMA user_version=2;
            \\COMMIT;
        );
    }

    pub fn persistedSchemaVersion(store: *Store) !i64 {
        return store.metaInt("schema_version");
    }

    pub fn load(store: *Store) !Snapshot {
        return store.loadInternal(false);
    }

    pub fn loadAll(store: *Store) !Snapshot {
        return store.loadInternal(true);
    }

    fn loadInternal(store: *Store, all_timers: bool) !Snapshot {
        var out = Snapshot{};
        out.revision = try store.metaInt("revision");
        out.selected_project_id = try store.metaInt("last_selected_project_id");
        try store.loadProjects(&out);
        if (out.selected_project_id == 0 and out.project_count > 0) out.selected_project_id = out.projects[0].id;
        if (all_timers) {
            try store.loadAllTimers(&out);
        } else if (out.selected_project_id != 0) {
            try store.loadTimers(out.selected_project_id, &out);
        }
        return out;
    }

    pub fn createProject(store: *Store, name: []const u8, now_ms: i64) !i64 {
        const clean = std.mem.trim(u8, name, " \t\r\n");
        if (clean.len == 0) return error.EmptyName;
        if (clean.len > max_name_bytes) return error.NameTooLong;
        const stmt = try store.prepare("INSERT INTO projects(name, created_at_ms, updated_at_ms) VALUES(?1, ?2, ?3);");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, clean);
        _ = c.sqlite3_bind_int64(stmt, 2, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 3, now_ms);
        try stepDone(stmt);
        const id = c.sqlite3_last_insert_rowid(store.db.?);
        try store.setSelectedProject(id);
        try store.bumpRevision();
        return id;
    }

    pub fn setSelectedProject(store: *Store, id: i64) !void {
        if (id != 0 and !try store.projectExists(id)) return error.NotFound;
        const stmt = try store.prepare("INSERT INTO meta(key, value) VALUES('last_selected_project_id', ?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value;");
        defer _ = c.sqlite3_finalize(stmt);
        var buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d}", .{id});
        try bindText(stmt, 1, text);
        try stepDone(stmt);
        try store.bumpRevision();
    }

    pub fn createTimer(store: *Store, project_id: i64, label: []const u8, duration_ms: i64, details: ?[]const u8, scheduled_start_ms: ?i64, now_ms: i64) !i64 {
        const clean_label = std.mem.trim(u8, label, " \t\r\n");
        if (clean_label.len == 0) return error.EmptyLabel;
        if (clean_label.len > max_label_bytes) return error.LabelTooLong;
        if (duration_ms <= 0) return error.InvalidDuration;
        const clean_details = if (details) |value| std.mem.trim(u8, value, " \t\r\n") else "";
        if (clean_details.len > max_details_bytes) return error.DetailsTooLong;
        if (!try store.projectExists(project_id)) return error.NotFound;
        if (scheduled_start_ms) |start| {
            if (start < now_ms) return error.ScheduledStartInPast;
            _ = std.math.add(i64, start, duration_ms) catch return error.IntegerOverflow;
        }
        const stmt = try store.prepare(
            "INSERT INTO timers(project_id, label, details, duration_ms, status, accumulated_ms, started_at_ms, scheduled_start_ms, schedule_consumed_at_ms, notification_claimed_at_ms, created_at_ms, updated_at_ms) " ++
                "VALUES(?1, ?2, ?3, ?4, 'paused', 0, 0, ?5, NULL, NULL, ?6, ?7);",
        );
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, project_id);
        try bindText(stmt, 2, clean_label);
        if (clean_details.len == 0) _ = c.sqlite3_bind_null(stmt, 3) else try bindText(stmt, 3, clean_details);
        _ = c.sqlite3_bind_int64(stmt, 4, duration_ms);
        if (scheduled_start_ms) |start| _ = c.sqlite3_bind_int64(stmt, 5, start) else _ = c.sqlite3_bind_null(stmt, 5);
        _ = c.sqlite3_bind_int64(stmt, 6, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 7, now_ms);
        try stepDone(stmt);
        try store.bumpRevision();
        return c.sqlite3_last_insert_rowid(store.db.?);
    }

    pub fn startTimer(store: *Store, timer_id: i64, now_ms: i64) !void {
        _ = try store.getTimer(timer_id);
        const stmt = try store.prepare(
            "UPDATE timers SET status='running', started_at_ms=?1, " ++
                "schedule_consumed_at_ms=CASE WHEN scheduled_start_ms IS NOT NULL AND schedule_consumed_at_ms IS NULL THEN ?2 ELSE schedule_consumed_at_ms END, " ++
                "updated_at_ms=?3 WHERE id=?4 AND status='paused';",
        );
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 2, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 3, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 4, timer_id);
        try stepDone(stmt);
        if (c.sqlite3_changes(store.db.?) != 0) try store.bumpRevision();
    }

    pub fn pauseTimer(store: *Store, timer_id: i64, now_ms: i64) !void {
        const timer = try store.getTimer(timer_id);
        if (timer.status != .running) return;
        const elapsed = timer.elapsedMs(now_ms);
        const stmt = try store.prepare("UPDATE timers SET status='paused', accumulated_ms=?1, started_at_ms=0, updated_at_ms=?2 WHERE id=?3;");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, elapsed);
        _ = c.sqlite3_bind_int64(stmt, 2, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 3, timer_id);
        try stepDone(stmt);
        try store.bumpRevision();
    }

    pub fn resetTimer(store: *Store, timer_id: i64, now_ms: i64) !void {
        _ = try store.getTimer(timer_id);
        const stmt = try store.prepare("UPDATE timers SET status='paused', accumulated_ms=0, started_at_ms=0, updated_at_ms=?1 WHERE id=?2;");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 2, timer_id);
        try stepDone(stmt);
        try store.bumpRevision();
    }

    pub fn deleteTimer(store: *Store, timer_id: i64) !void {
        const stmt = try store.prepare("DELETE FROM timers WHERE id=?1;");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, timer_id);
        try stepDone(stmt);
        if (c.sqlite3_changes(store.db.?) == 0) return error.NotFound;
        try store.bumpRevision();
    }

    pub fn reconcile(store: *Store, now_ms: i64) !ReconcileResult {
        var result = ReconcileResult{};
        try store.exec("BEGIN IMMEDIATE;");
        errdefer store.exec("ROLLBACK;") catch {};

        const notification_stmt = try store.prepare(
            "SELECT id, project_id, label, details, duration_ms, status, accumulated_ms, started_at_ms, " ++
                "COALESCE(scheduled_start_ms,0), COALESCE(schedule_consumed_at_ms,0), COALESCE(notification_claimed_at_ms,0), created_at_ms, updated_at_ms " ++
                "FROM timers WHERE scheduled_start_ms IS NOT NULL AND scheduled_start_ms<=?1 AND schedule_consumed_at_ms IS NULL AND notification_claimed_at_ms IS NULL " ++
                "ORDER BY scheduled_start_ms, created_at_ms, id;",
        );
        defer _ = c.sqlite3_finalize(notification_stmt);
        _ = c.sqlite3_bind_int64(notification_stmt, 1, now_ms);
        while (c.sqlite3_step(notification_stmt) == c.SQLITE_ROW and result.notification_count < max_timers) {
            result.notifications[result.notification_count] = readTimer(notification_stmt);
            result.notification_count += 1;
        }
        if (result.notification_count > 0) {
            const claim_stmt = try store.prepare(
                "UPDATE timers SET notification_claimed_at_ms=?1 WHERE scheduled_start_ms IS NOT NULL AND scheduled_start_ms<=?2 AND schedule_consumed_at_ms IS NULL AND notification_claimed_at_ms IS NULL;",
            );
            defer _ = c.sqlite3_finalize(claim_stmt);
            _ = c.sqlite3_bind_int64(claim_stmt, 1, now_ms);
            _ = c.sqlite3_bind_int64(claim_stmt, 2, now_ms);
            try stepDone(claim_stmt);
        }

        if (!try store.hasRunningTimer()) {
            const due_stmt = try store.prepare(
                "SELECT id FROM timers WHERE scheduled_start_ms IS NOT NULL AND scheduled_start_ms<=?1 AND schedule_consumed_at_ms IS NULL " ++
                    "ORDER BY scheduled_start_ms, created_at_ms, id LIMIT 1;",
            );
            defer _ = c.sqlite3_finalize(due_stmt);
            _ = c.sqlite3_bind_int64(due_stmt, 1, now_ms);
            if (c.sqlite3_step(due_stmt) == c.SQLITE_ROW) {
                result.started_timer_id = c.sqlite3_column_int64(due_stmt, 0);
                const start_stmt = try store.prepare("UPDATE timers SET status='running', started_at_ms=?1, schedule_consumed_at_ms=?2, updated_at_ms=?3 WHERE id=?4;");
                defer _ = c.sqlite3_finalize(start_stmt);
                _ = c.sqlite3_bind_int64(start_stmt, 1, now_ms);
                _ = c.sqlite3_bind_int64(start_stmt, 2, now_ms);
                _ = c.sqlite3_bind_int64(start_stmt, 3, now_ms);
                _ = c.sqlite3_bind_int64(start_stmt, 4, result.started_timer_id);
                try stepDone(start_stmt);
            }
        }
        if (result.notification_count > 0 or result.started_timer_id != 0) try store.bumpRevision();
        try store.exec("COMMIT;");
        return result;
    }

    fn pragmaUserVersion(store: *Store) !i64 {
        const stmt = try store.prepare("PRAGMA user_version;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return c.sqlite3_column_int64(stmt, 0);
    }

    fn prepare(store: *Store, sql: [:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(store.db.?, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        return stmt.?;
    }

    fn metaInt(store: *Store, key: []const u8) !i64 {
        const stmt = try store.prepare("SELECT value FROM meta WHERE key=?1;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, key);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return std.fmt.parseInt(i64, textColumn(stmt, 0), 10) catch 0;
    }

    fn bumpRevision(store: *Store) !void {
        try store.exec("UPDATE meta SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) WHERE key='revision';");
    }

    fn projectExists(store: *Store, id: i64) !bool {
        const stmt = try store.prepare("SELECT 1 FROM projects WHERE id=?1;");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, id);
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    fn hasRunningTimer(store: *Store) !bool {
        const stmt = try store.prepare("SELECT 1 FROM timers WHERE status='running' LIMIT 1;");
        defer _ = c.sqlite3_finalize(stmt);
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    fn getTimer(store: *Store, id: i64) !Timer {
        const stmt = try store.prepare(timer_select ++ " WHERE id=?1;");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.NotFound;
        return readTimer(stmt);
    }

    fn loadProjects(store: *Store, out: *Snapshot) !void {
        const stmt = try store.prepare("SELECT id, name, created_at_ms, updated_at_ms FROM projects ORDER BY updated_at_ms DESC, id DESC;");
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW and out.project_count < max_projects) {
            var project = Project{
                .id = c.sqlite3_column_int64(stmt, 0),
                .created_at_ms = c.sqlite3_column_int64(stmt, 2),
                .updated_at_ms = c.sqlite3_column_int64(stmt, 3),
            };
            project.setName(textColumn(stmt, 1));
            out.projects[out.project_count] = project;
            out.project_count += 1;
        }
    }

    fn loadTimers(store: *Store, project_id: i64, out: *Snapshot) !void {
        const stmt = try store.prepare(timer_select ++ " WHERE project_id=?1 ORDER BY created_at_ms DESC, id DESC;");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, project_id);
        try appendTimers(stmt, out);
    }

    fn loadAllTimers(store: *Store, out: *Snapshot) !void {
        const stmt = try store.prepare(timer_select ++ " ORDER BY COALESCE(scheduled_start_ms, 9223372036854775807), created_at_ms, id;");
        defer _ = c.sqlite3_finalize(stmt);
        try appendTimers(stmt, out);
    }
};

const timer_select =
    "SELECT id, project_id, label, details, duration_ms, status, accumulated_ms, started_at_ms, " ++
    "COALESCE(scheduled_start_ms,0), COALESCE(schedule_consumed_at_ms,0), COALESCE(notification_claimed_at_ms,0), created_at_ms, updated_at_ms FROM timers";

fn appendTimers(stmt: *c.sqlite3_stmt, out: *Snapshot) !void {
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW and out.timer_count < max_timers) {
        out.timers[out.timer_count] = readTimer(stmt);
        out.timer_count += 1;
    }
}

fn readTimer(stmt: *c.sqlite3_stmt) Timer {
    var timer = Timer{
        .id = c.sqlite3_column_int64(stmt, 0),
        .project_id = c.sqlite3_column_int64(stmt, 1),
        .duration_ms = c.sqlite3_column_int64(stmt, 4),
        .status = if (std.mem.eql(u8, textColumn(stmt, 5), "running")) .running else .paused,
        .accumulated_ms = c.sqlite3_column_int64(stmt, 6),
        .started_at_ms = c.sqlite3_column_int64(stmt, 7),
        .scheduled_start_ms = c.sqlite3_column_int64(stmt, 8),
        .schedule_consumed_at_ms = c.sqlite3_column_int64(stmt, 9),
        .notification_claimed_at_ms = c.sqlite3_column_int64(stmt, 10),
        .created_at_ms = c.sqlite3_column_int64(stmt, 11),
        .updated_at_ms = c.sqlite3_column_int64(stmt, 12),
    };
    timer.setLabel(textColumn(stmt, 2));
    timer.setDetails(textColumn(stmt, 3));
    return timer;
}

pub fn parseDuration(text: []const u8) !i64 {
    const input = std.mem.trim(u8, text, " \t\r\n");
    if (input.len == 0) return error.InvalidDuration;
    var index: usize = 0;
    var last_rank: u8 = 4;
    var total: i64 = 0;
    var component_count: usize = 0;
    while (index < input.len) {
        while (index < input.len and std.ascii.isWhitespace(input[index])) index += 1;
        if (index == input.len) break;
        const digits_start = index;
        while (index < input.len and std.ascii.isDigit(input[index])) index += 1;
        if (digits_start == index or index == input.len) return error.InvalidDuration;
        const value = std.fmt.parseInt(i64, input[digits_start..index], 10) catch return error.IntegerOverflow;
        if (value <= 0) return error.InvalidDuration;
        const unit = input[index];
        index += 1;
        const rank: u8, const multiplier: i64 = switch (unit) {
            'h' => .{ 3, 3_600_000 },
            'm' => .{ 2, 60_000 },
            's' => .{ 1, 1_000 },
            else => return error.UnsupportedDurationUnit,
        };
        if (rank >= last_rank) return error.InvalidDurationOrder;
        last_rank = rank;
        const amount = std.math.mul(i64, value, multiplier) catch return error.IntegerOverflow;
        total = std.math.add(i64, total, amount) catch return error.IntegerOverflow;
        component_count += 1;
        if (index < input.len and !std.ascii.isWhitespace(input[index])) return error.InvalidDuration;
    }
    if (component_count == 0 or total <= 0) return error.InvalidDuration;
    return total;
}

pub fn parseRfc3339(text: []const u8) !i64 {
    const input = std.mem.trim(u8, text, " \t\r\n");
    if (input.len < 19) return error.InvalidRfc3339;
    if (input[4] != '-' or input[7] != '-' or (input[10] != 'T' and input[10] != 't') or input[13] != ':' or input[16] != ':') return error.InvalidRfc3339;
    const year = try parseDigits(input, 0, 4);
    const month = try parseDigits(input, 5, 2);
    const day = try parseDigits(input, 8, 2);
    const hour = try parseDigits(input, 11, 2);
    const minute = try parseDigits(input, 14, 2);
    const second = try parseDigits(input, 17, 2);
    if (year == 0 or month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) or hour > 23 or minute > 59 or second > 59) return error.InvalidRfc3339;

    var index: usize = 19;
    var millis: i64 = 0;
    if (index < input.len and input[index] == '.') {
        index += 1;
        const fraction_start = index;
        var digits: usize = 0;
        while (index < input.len and std.ascii.isDigit(input[index])) : (index += 1) {
            if (digits < 3) millis = millis * 10 + @as(i64, input[index] - '0');
            digits += 1;
        }
        if (fraction_start == index) return error.InvalidRfc3339;
        while (digits < 3) : (digits += 1) millis *= 10;
    }

    var offset_minutes: i64 = 0;
    if (index < input.len and (input[index] == 'Z' or input[index] == 'z')) {
        index += 1;
    } else {
        if (index + 6 != input.len or (input[index] != '+' and input[index] != '-') or input[index + 3] != ':') return error.ExplicitOffsetRequired;
        const sign: i64 = if (input[index] == '+') 1 else -1;
        const offset_hour = try parseDigits(input, index + 1, 2);
        const offset_minute = try parseDigits(input, index + 4, 2);
        if (offset_hour > 23 or offset_minute > 59) return error.InvalidRfc3339;
        offset_minutes = sign * @as(i64, @intCast(offset_hour * 60 + offset_minute));
        index += 6;
    }
    if (index != input.len) return error.InvalidRfc3339;

    const days = daysFromCivil(@intCast(year), @intCast(month), @intCast(day));
    var seconds_total: i128 = @as(i128, days) * 86_400 + @as(i128, hour) * 3_600 + @as(i128, minute) * 60 + second;
    seconds_total -= @as(i128, offset_minutes) * 60;
    const result = seconds_total * 1_000 + millis;
    if (result < std.math.minInt(i64) or result > std.math.maxInt(i64)) return error.IntegerOverflow;
    return @intCast(result);
}

fn parseDigits(input: []const u8, start: usize, len: usize) !u32 {
    if (start + len > input.len) return error.InvalidRfc3339;
    for (input[start .. start + len]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidRfc3339;
    return std.fmt.parseInt(u32, input[start .. start + len], 10) catch error.InvalidRfc3339;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn daysFromCivil(year_input: i64, month_input: i64, day: i64) i64 {
    var year = year_input;
    if (month_input <= 2) year -= 1;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month = month_input + (if (month_input > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), null) != c.SQLITE_OK) return error.BindFailed;
}

fn stepDone(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
}

fn textColumn(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return ptr[0..len];
}

test "duration parser accepts ordered components and rejects malformed input" {
    try std.testing.expectEqual(@as(i64, 25 * 60_000), try parseDuration("25m"));
    try std.testing.expectEqual(@as(i64, 5_400_000), try parseDuration("1h 30m"));
    try std.testing.expectEqual(@as(i64, 3_661_000), try parseDuration("1h 1m 1s"));
    for ([_][]const u8{ "", "0m", "1d", "30m 1h", "1h 2h", "1.5h", "-1m", "1m30s" }) |invalid| {
        if (parseDuration(invalid)) |_| return error.TestExpectedError else |_| {}
    }
    try std.testing.expectError(error.IntegerOverflow, parseDuration("9223372036854775807h"));
}

test "RFC 3339 parser handles offsets and validation" {
    try std.testing.expectEqual(@as(i64, 0), try parseRfc3339("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 0), try parseRfc3339("1970-01-01T05:30:00+05:30"));
    try std.testing.expectEqual(@as(i64, 1_234), try parseRfc3339("1970-01-01T00:00:01.2349Z"));
    try std.testing.expectError(error.ExplicitOffsetRequired, parseRfc3339("2026-07-21T12:00:00"));
    try std.testing.expectError(error.InvalidRfc3339, parseRfc3339("2025-02-29T12:00:00Z"));
}

test "migration is destructive once and persists its version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/migration.sqlite", .{tmp.sub_path});
    var db: ?*c.sqlite3 = null;
    const path_z = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(path_z);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(path_z.ptr, &db));
    _ = c.sqlite3_exec(db.?, "CREATE TABLE projects(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO projects VALUES(1,'old');", null, null, null);
    _ = c.sqlite3_close(db);

    var store = try Store.open(path);
    try std.testing.expectEqual(schema_version, try store.persistedSchemaVersion());
    try std.testing.expectEqual(@as(usize, 0), (try store.load()).project_count);
    _ = try store.createProject("kept", 10);
    store.close();

    var reopened = try Store.open(path);
    defer reopened.close();
    const snapshot = try reopened.load();
    try std.testing.expectEqual(@as(usize, 1), snapshot.project_count);
    try std.testing.expectEqualStrings("kept", snapshot.projects[0].name());
}

test "timer lifecycle countdown reset and consumed schedule" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/lifecycle.sqlite", .{tmp.sub_path});
    var store = try Store.open(path);
    defer store.close();
    const project_id = try store.createProject("Work", 1_000);
    try std.testing.expectError(error.ScheduledStartInPast, store.createTimer(project_id, "Past", 1_000, null, 999, 1_000));
    var oversized_details: [max_details_bytes + 1]u8 = undefined;
    @memset(&oversized_details, 'x');
    try std.testing.expectError(error.DetailsTooLong, store.createTimer(project_id, "Too detailed", 1_000, &oversized_details, null, 1_000));
    try std.testing.expectError(error.IntegerOverflow, store.createTimer(project_id, "Overflow", 10, null, std.math.maxInt(i64) - 5, 1_000));
    const timer_id = try store.createTimer(project_id, "Focus", 2_000, "Ship it", 2_000, 1_000);
    try store.startTimer(timer_id, 1_500);
    var timer = (try store.load()).timers[0];
    try std.testing.expectEqual(ScheduleState.consumed, timer.scheduleState(1_500));
    try std.testing.expectEqual(@as(i64, 1_000), timer.remainingMs(2_500));
    try std.testing.expectEqual(@as(i64, 1_000), timer.overdueMs(4_500));
    try store.resetTimer(timer_id, 4_500);
    timer = (try store.load()).timers[0];
    try std.testing.expectEqual(Status.paused, timer.status);
    try std.testing.expectEqual(@as(i64, 0), timer.accumulated_ms);
    try std.testing.expectEqual(ScheduleState.consumed, timer.scheduleState(5_000));
}

test "reconcile claims once, waits behind active timer, and starts oldest first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/queue.sqlite", .{tmp.sub_path});
    var store = try Store.open(path);
    defer store.close();
    const project_id = try store.createProject("Queue", 100);
    const active = try store.createTimer(project_id, "Active", 60_000, null, null, 100);
    try store.startTimer(active, 200);
    const oldest = try store.createTimer(project_id, "Oldest", 60_000, null, 1_000, 300);
    const newest = try store.createTimer(project_id, "Newest", 60_000, null, 1_000, 400);
    const last = try store.createTimer(project_id, "Last", 60_000, null, 1_500, 500);

    const waiting = try store.reconcile(2_000);
    try std.testing.expectEqual(@as(usize, 3), waiting.notification_count);
    try std.testing.expectEqual(@as(i64, 0), waiting.started_timer_id);
    try std.testing.expectEqual(@as(usize, 0), (try store.reconcile(2_100)).notification_count);
    try store.pauseTimer(active, 2_200);
    try std.testing.expectEqual(oldest, (try store.reconcile(2_200)).started_timer_id);
    try store.resetTimer(oldest, 2_300);
    try std.testing.expectEqual(newest, (try store.reconcile(2_300)).started_timer_id);
    try store.deleteTimer(newest);
    try std.testing.expectEqual(last, (try store.reconcile(2_400)).started_timer_id);
    const snapshot = try store.load();
    for (snapshot.timers[0..snapshot.timer_count]) |timer| {
        if (timer.id == oldest) {
            try std.testing.expectEqual(ScheduleState.consumed, timer.scheduleState(3_000));
            try std.testing.expectEqual(@as(i64, 1_200), timer.scheduleDelayMs());
        }
    }
}

test "notification claims and missed schedule reconciliation survive relaunch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/relaunch.sqlite", .{tmp.sub_path});
    {
        var store = try Store.open(path);
        defer store.close();
        const project_id = try store.createProject("Relaunch", 100);
        _ = try store.createTimer(project_id, "Missed", 60_000, null, 1_000, 100);
    }
    {
        var reopened = try Store.open(path);
        defer reopened.close();
        const first = try reopened.reconcile(5_000);
        try std.testing.expectEqual(@as(usize, 1), first.notification_count);
        try std.testing.expectEqual(@as(i64, 1), first.started_timer_id);
    }
    {
        var reopened_again = try Store.open(path);
        defer reopened_again.close();
        const second = try reopened_again.reconcile(6_000);
        try std.testing.expectEqual(@as(usize, 0), second.notification_count);
        try std.testing.expectEqual(@as(i64, 0), second.started_timer_id);
        const timer = (try reopened_again.load()).timers[0];
        try std.testing.expect(timer.notification_claimed_at_ms != 0);
        try std.testing.expect(timer.schedule_consumed_at_ms != 0);
    }
}
