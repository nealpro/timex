const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");
const theme = @import("theme.zig");

const canvas = native_sdk.canvas;

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const Ui = canvas.Ui(Msg);

const window_pad: f32 = 18;
const gap: f32 = 12;
const project_width: f32 = 250;

pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .surface } }, .{
        header(ui, model),
        ui.row(.{ .grow = 1, .padding = window_pad, .gap = gap }, .{
            projectRack(ui, model),
            timerBay(ui, model),
        }),
        ui.statusBar(.{}, model.status()),
    });
}

fn header(ui: *Ui, model: *const Model) Ui.Node {
    return ui.row(.{
        .height = model.header_height,
        .padding = 10,
        .gap = 10,
        .cross = .center,
        .window_drag = true,
        .style_tokens = .{ .background = .surface },
        .semantics = .{ .label = "Timex header" },
    }, .{
        ui.el(.stack, .{ .width = model.chrome_leading }, .{}),
        stamp(ui, "T I M E X"),
        ui.spacer(1),
        readout(ui, "PROJECT TIMER // MCP READY", .text_muted),
        ui.row(.{ .gap = 4, .cross = .center }, .{
            ui.icon(.{ .width = 9, .height = 9, .style_tokens = .{ .foreground = if (model.runningCount() > 0) .accent else .text_muted } }, "circle-dot"),
            readout(ui, if (model.runningCount() > 0) "RUN" else "STBY", .text_muted),
        }),
    });
}

fn projectRack(ui: *Ui, model: *const Model) Ui.Node {
    return ui.panel(.{
        .width = project_width,
        .padding = 12,
        .style_tokens = .{ .background = .background, .radius = .sm },
        .semantics = .{ .label = "Project rack" },
    }, ui.column(.{ .gap = 10, .grow = 1 }, .{
        glassTitle(ui, "PROJECT RACK"),
        ui.el(.text_field, .{
            .text = model.projectDraft(),
            .placeholder = "PROJECT NAME",
            .on_input = Ui.inputMsg(.project_edit),
            .on_submit = .create_project,
            .semantics = .{ .label = "Project name" },
        }, .{}),
        ui.button(.{
            .variant = .outline,
            .on_press = .create_project,
            .disabled = model.projectDraftEmpty(),
            .semantics = .{ .label = "Create project" },
        }, "NEW PROJECT"),
        ui.el(.separator, .{}, .{}),
        ui.el(.list, .{ .grow = 1, .gap = 6, .semantics = .{ .label = "Projects" } }, ui.eachCtx(model.selected_project_id, model.projects[0..model.project_count], projectKey, projectRow)),
    }));
}

fn projectKey(project: *const model_mod.Project) canvas.UiKey {
    return canvas.uiKey(project.id);
}

fn projectRow(ui: *Ui, selected_id: i64, project: *const model_mod.Project) Ui.Node {
    return ui.listItem(.{
        .height = 34,
        .selected = project.id == selected_id,
        .on_press = Msg{ .select_project = project.id },
        .semantics = .{ .label = project.name() },
    }, project.name());
}

fn timerBay(ui: *Ui, model: *const Model) Ui.Node {
    return ui.panel(.{
        .grow = 1,
        .padding = 14,
        .style_tokens = .{ .background = .background, .radius = .sm },
        .semantics = .{ .label = "Timer bay" },
    }, ui.column(.{ .gap = 12, .grow = 1 }, .{
        ui.row(.{ .gap = 10, .cross = .center }, .{
            glassTitle(ui, model.selectedProjectName()),
            ui.spacer(1),
            readout(ui, "TIMERS", .info),
        }),
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.el(.text_field, .{
                .grow = 1,
                .text = model.timerDraft(),
                .placeholder = "TIMER LABEL",
                .on_input = Ui.inputMsg(.timer_edit),
                .on_submit = .create_timer,
                .semantics = .{ .label = "Timer label" },
            }, .{}),
            ui.el(.text_field, .{
                .width = 120,
                .text = model.durationDraft(),
                .placeholder = "25m / 1h 30m",
                .on_input = Ui.inputMsg(.duration_edit),
                .on_submit = .create_timer,
                .semantics = .{ .label = "Timer duration" },
            }, .{}),
            ui.el(.text_field, .{
                .width = 260,
                .text = model.scheduledStartDraft(),
                .placeholder = "2026-07-21T15:30:00+05:30",
                .on_input = Ui.inputMsg(.scheduled_start_edit),
                .on_submit = .create_timer,
                .semantics = .{ .label = "Optional scheduled start with timezone offset" },
            }, .{}),
            ui.button(.{
                .variant = .outline,
                .on_press = .create_timer,
                .disabled = !model.timerDraftValid(),
                .semantics = .{ .label = "Create timer" },
            }, "ADD"),
        }),
        ui.el(.textarea, .{
            .height = 58,
            .text = model.detailsDraft(),
            .placeholder = "OPTIONAL DETAILS — PURPOSE, USEFUL STEPS, COMPLETION CRITERIA",
            .on_input = Ui.inputMsg(.details_edit),
            .semantics = .{ .label = "Optional timer details" },
        }, .{}),
        ui.el(.separator, .{}, .{}),
        if (model.timer_count == 0)
            emptyTimers(ui, model)
        else
            ui.scroll(.{ .grow = 1, .semantics = .{ .label = "Timer list" } }, ui.column(.{ .gap = 8 }, ui.eachCtx(model.now_ms, model.timers[0..model.timer_count], timerKey, timerRow))),
    }));
}

fn timerKey(timer: *const model_mod.Timer) canvas.UiKey {
    return canvas.uiKey(timer.id);
}

fn timerRow(ui: *Ui, now_ms: i64, timer: *const model_mod.Timer) Ui.Node {
    var duration_buffer: [32]u8 = undefined;
    const countdown = model_mod.formatDuration(&duration_buffer, if (timer.overdue_ms > 0) timer.overdue_ms else timer.remaining_ms);
    var timing_buffer: [64]u8 = undefined;
    const timing = std.fmt.bufPrint(&timing_buffer, "{s} {s}", .{ if (timer.overdue_ms > 0) "OVERDUE" else "REMAINING", countdown }) catch countdown;
    var schedule_buffer: [180]u8 = undefined;
    var drift_buffer: [32]u8 = undefined;
    const drift = model_mod.formatDuration(&drift_buffer, if (timer.schedule_delay_ms < 0) -timer.schedule_delay_ms else timer.schedule_delay_ms);
    const schedule = if (timer.scheduled_start_ms == 0)
        "AD HOC"
    else if (timer.schedule_state == .consumed and timer.schedule_delay_ms != 0)
        std.fmt.bufPrint(&schedule_buffer, "{s} // {s} → {s} // {s}{s}", .{ @tagName(timer.schedule_state), timer.scheduledStartLocal(), timer.plannedEndLocal(), if (timer.schedule_delay_ms > 0) "LATE +" else "EARLY -", drift }) catch @tagName(timer.schedule_state)
    else
        std.fmt.bufPrint(&schedule_buffer, "{s} // {s} → {s}", .{ @tagName(timer.schedule_state), timer.scheduledStartLocal(), timer.plannedEndLocal() }) catch @tagName(timer.schedule_state);
    _ = now_ms;
    return ui.panel(.{
        .padding = 10,
        .style_tokens = .{ .background = .surface_subtle, .radius = .sm },
        .semantics = .{ .label = timer.label() },
    }, ui.column(.{ .gap = 6 }, .{
        ui.row(.{ .gap = 10, .cross = .center }, .{
            ui.column(.{ .gap = 4, .grow = 1 }, .{
                readout(ui, timer.label(), if (timer.status == .running) .accent else .success),
                readout(ui, timing, if (timer.overdue_ms > 0) .destructive else .info),
                readout(ui, schedule, if (timer.schedule_state == .waiting) .warning else .text_muted),
            }),
            if (timer.status == .running)
                ui.button(.{ .variant = .outline, .icon = "pause", .on_press = Msg{ .pause_timer = timer.id }, .semantics = .{ .label = "Pause timer" } }, "")
            else
                ui.button(.{ .variant = .outline, .icon = "play", .on_press = Msg{ .start_timer = timer.id }, .semantics = .{ .label = "Start timer" } }, ""),
            ui.button(.{ .variant = .outline, .icon = "refresh-cw", .on_press = Msg{ .reset_timer = timer.id }, .semantics = .{ .label = "Reset timer" } }, ""),
            ui.button(.{ .variant = .outline, .icon = "trash", .on_press = Msg{ .delete_timer = timer.id }, .semantics = .{ .label = "Delete timer" } }, ""),
        }),
        if (timer.details().len > 0) readout(ui, timer.details(), .text_muted) else ui.el(.stack, .{ .height = 0 }, .{}),
    }));
}

fn emptyTimers(ui: *Ui, model: *const Model) Ui.Node {
    return ui.column(.{ .grow = 1, .main = .center, .cross = .center, .gap = 8 }, .{
        glassTitle(ui, if (model.hasSelectedProject()) "NO TIMERS" else "SELECT PROJECT"),
        readout(ui, if (model.hasSelectedProject()) "ADD A LABELED TIMER TO BEGIN" else "CREATE OR PICK A PROJECT", .info),
    });
}

fn stamp(ui: *Ui, text: []const u8) Ui.Node {
    var node = ui.paragraph(.{ .width = 120, .semantics = .{ .label = "Brand" } }, &.{
        .{ .text = text, .weight = .bold, .monospace = true, .color = .text, .scale = 1.0 },
    });
    node.widget.text_alignment = .center;
    return node;
}

fn glassTitle(ui: *Ui, text: []const u8) Ui.Node {
    return ui.paragraph(.{}, &.{
        .{ .text = text, .monospace = true, .weight = .bold, .scale = 2.0, .color = .accent },
    });
}

fn readout(ui: *Ui, text: []const u8, color: canvas.ColorTokenName) Ui.Node {
    return ui.paragraph(.{}, &.{
        .{ .text = text, .monospace = true, .color = color, .scale = 1.0 },
    });
}
