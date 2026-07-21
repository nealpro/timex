---
name: timex-agent
description: Use when planning, inspecting, or controlling Timex, the local project-based timer app exposed over MCP. Prefer semantic Timex tools for projects and timers, and use Native UI automation only when visual state must be inspected or driven.
---

# Timex Agent

## Connection

- Launch the MCP server from the Timex repo with `zig-out/bin/timex-mcp`.
- Build the standalone MCP/store package with `zig build mcp` or from `mcp/` with `zig build`.
- Set `TIMEX_DB_PATH=/path/to/timex.sqlite` when you need a test database or a non-default store.
- The Native app uses `timex-store`; set `TIMEX_STORE_BIN=/path/to/timex-store` if the default `zig-out/bin/timex-store` is not reachable from the app's working directory.
- If the running app was launched with Native automation enabled, UI artifacts live in `.zig-cache/native-sdk-automation`.

## Default Workflow

1. Read `timex://current-view` or `timex://state-summary` before making changes.
2. Prefer semantic tools over raw UI automation:
   - `project_create`
   - `project_select`
   - `timer_create`
   - `timer_start`
   - `timer_pause`
   - `timer_delete`
3. Use `ui_snapshot` to inspect the visible app when the user asks about what is currently on screen.
4. Use `ui_command` only for UI-specific validation or when the task explicitly requires driving widgets.

## Data Rules

- Projects are separate planning contexts; select the intended project before creating timers.
- Timer elapsed time is derived from stored accumulated time plus the active running interval.
- Deleting a timer is permanent in v1.
- Treat MCP tool failures as authoritative and re-read state before retrying.
