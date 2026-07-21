---
name: timex-agent
description: Plan, time-box, schedule, inspect, and control user-owned tasks in Timex, the local project-based timer app exposed over MCP. Use when a user wants a daily plan, focused work blocks, calendar starts, task durations, or Timex project/timer operations. Prefer semantic Timex tools; use Native UI automation only for visible UI inspection or interaction.
---

# Timex Agent

## Connect

- Launch `zig-out/bin/timex-mcp` from the Timex repository.
- Build the standalone MCP/store package with `zig build mcp`.
- Set `TIMEX_DB_PATH=/path/to/timex.sqlite` only for a test or non-default store.
- Read `timex://state-summary` before proposing or making changes. Read `timex://current-view` when the selected project matters.

## Plan Mode

1. Inspect Timex state read-only.
2. Identify tasks the user will perform. Exclude the coding agent's implementation, testing, or tool-use steps.
3. Propose a schedule containing project, local start time, estimated duration, short label, and concise outcome-oriented details for every task.
4. Ask for missing availability. Resolve ambiguous dates, times, and timezones before proposing exact calendar starts.
5. Propose a new project when no existing project fits.
6. Do not create or modify projects or timers in Plan Mode.

## Apply an Approved Schedule

Treat the user's approval to implement the proposed plan as authorization to create its project and paused timers before other execution work.

1. Re-read `timex://state-summary` immediately before writing.
2. Match existing projects and timers by project, label, duration, details, and planned start; avoid duplicates.
3. Create a proposed project only when no suitable project exists.
4. Create each timer with `duration`, optional `details`, and optional `scheduled_start`.
5. Keep scheduled timers paused. Timex starts them while the app is open when their start arrives and no timer is running.
6. Do not start the first timer unless the approved schedule explicitly begins now. For “start now,” create an unscheduled timer, then call `timer_start` explicitly.
7. Re-read state and report the created or reused project and timer IDs.

## Semantic Tools

- `project_create`, `project_select`
- `timer_create` with required `project_id`, `label`, and `duration`
- `timer_start`, `timer_pause`, `timer_reset`, `timer_delete`

Use durations such as `25m`, `1h`, or `1h 30m`. Use RFC 3339 calendar starts with an explicit offset, such as `2026-07-21T15:30:00+05:30`. Timex stores calendar instants in UTC and displays them in the system timezone.

## Content and Safety

- Store only user-facing purpose, useful steps, and completion criteria in timer details.
- Keep secrets, chat-only context, hidden reasoning, and model chain-of-thought out of Timex.
- Treat tool errors as authoritative. Re-read state before retrying.
- Starting a scheduled timer manually consumes its pending schedule. Resetting pauses it and clears elapsed time without requeuing that schedule.
- Prefer semantic tools over `ui_command`. Use `ui_snapshot` only when the visible app state is relevant.
