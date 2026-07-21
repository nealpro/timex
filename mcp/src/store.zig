const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

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
    status: Status = .paused,
    accumulated_ms: i64 = 0,
    started_at_ms: i64 = 0,
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

    pub fn elapsedMs(timer: *const Timer, now_ms: i64) i64 {
        if (timer.status == .running and timer.started_at_ms > 0) {
            return timer.accumulated_ms + @max(@as(i64, 0), now_ms - timer.started_at_ms);
        }
        return timer.accumulated_ms;
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
        try store.exec(
            \\CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            \\CREATE TABLE IF NOT EXISTS projects(
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            \\  created_at_ms INTEGER NOT NULL,
            \\  updated_at_ms INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS timers(
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            \\  label TEXT NOT NULL,
            \\  status TEXT NOT NULL CHECK(status IN ('paused','running')),
            \\  accumulated_ms INTEGER NOT NULL DEFAULT 0,
            \\  started_at_ms INTEGER NOT NULL DEFAULT 0,
            \\  created_at_ms INTEGER NOT NULL,
            \\  updated_at_ms INTEGER NOT NULL
            \\);
            \\INSERT OR IGNORE INTO meta(key, value) VALUES('revision', '0');
            \\INSERT OR IGNORE INTO meta(key, value) VALUES('last_selected_project_id', '0');
        );
    }

    pub fn load(store: *Store) !Snapshot {
        var out = Snapshot{};
        out.revision = try store.metaInt("revision");
        out.selected_project_id = try store.metaInt("last_selected_project_id");
        try store.loadProjects(&out);
        if (out.selected_project_id == 0 and out.project_count > 0) out.selected_project_id = out.projects[0].id;
        if (out.selected_project_id != 0) try store.loadTimers(out.selected_project_id, &out);
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

    pub fn createTimer(store: *Store, project_id: i64, label: []const u8, now_ms: i64) !i64 {
        const clean = std.mem.trim(u8, label, " \t\r\n");
        if (clean.len == 0) return error.EmptyLabel;
        if (clean.len > max_label_bytes) return error.LabelTooLong;
        if (!try store.projectExists(project_id)) return error.NotFound;
        const stmt = try store.prepare("INSERT INTO timers(project_id, label, status, accumulated_ms, started_at_ms, created_at_ms, updated_at_ms) VALUES(?1, ?2, 'paused', 0, 0, ?3, ?4);");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, project_id);
        try bindText(stmt, 2, clean);
        _ = c.sqlite3_bind_int64(stmt, 3, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 4, now_ms);
        try stepDone(stmt);
        try store.bumpRevision();
        return c.sqlite3_last_insert_rowid(store.db.?);
    }

    pub fn startTimer(store: *Store, timer_id: i64, now_ms: i64) !void {
        const stmt = try store.prepare("UPDATE timers SET status='running', started_at_ms=?1, updated_at_ms=?2 WHERE id=?3 AND status='paused';");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 2, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 3, timer_id);
        try stepDone(stmt);
        if (c.sqlite3_changes(store.db.?) == 0) return error.NotFound;
        try store.bumpRevision();
    }

    pub fn pauseTimer(store: *Store, timer_id: i64, now_ms: i64) !void {
        var timer = try store.getTimer(timer_id);
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

    pub fn deleteTimer(store: *Store, timer_id: i64) !void {
        const stmt = try store.prepare("DELETE FROM timers WHERE id=?1;");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, timer_id);
        try stepDone(stmt);
        if (c.sqlite3_changes(store.db.?) == 0) return error.NotFound;
        try store.bumpRevision();
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

    fn getTimer(store: *Store, id: i64) !Timer {
        const stmt = try store.prepare("SELECT id, project_id, label, status, accumulated_ms, started_at_ms, created_at_ms, updated_at_ms FROM timers WHERE id=?1;");
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
        const stmt = try store.prepare("SELECT id, project_id, label, status, accumulated_ms, started_at_ms, created_at_ms, updated_at_ms FROM timers WHERE project_id=?1 ORDER BY created_at_ms DESC, id DESC;");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, project_id);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW and out.timer_count < max_timers) {
            out.timers[out.timer_count] = readTimer(stmt);
            out.timer_count += 1;
        }
    }
};

fn readTimer(stmt: *c.sqlite3_stmt) Timer {
    var timer = Timer{
        .id = c.sqlite3_column_int64(stmt, 0),
        .project_id = c.sqlite3_column_int64(stmt, 1),
        .status = if (std.mem.eql(u8, textColumn(stmt, 3), "running")) .running else .paused,
        .accumulated_ms = c.sqlite3_column_int64(stmt, 4),
        .started_at_ms = c.sqlite3_column_int64(stmt, 5),
        .created_at_ms = c.sqlite3_column_int64(stmt, 6),
        .updated_at_ms = c.sqlite3_column_int64(stmt, 7),
    };
    timer.setLabel(textColumn(stmt, 2));
    return timer;
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
