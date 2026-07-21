# Timex

Deck-styled native timer app for project-scoped work sessions, exposed to coding agents over MCP.

## Layout

- `app/` is the Native SDK app package. It contains the UI, model, assets, and Native manifest.
- `mcp/` is the standalone Zig package for SQLite storage, `timex-mcp`, and the `timex-store` helper CLI.
- The root `build.zig` only orchestrates both packages. It does not import or require a checked-in Native SDK dependency.

## Features

- Create and select projects.
- Create, start, pause, and delete labeled timers inside a project.
- Persist projects and timers in SQLite.
- Run `timex-mcp` as a stdio MCP server for agent control.
- Let the Native app talk to storage through `timex-store`, so SQLite is isolated from the app binary.

## Build

```sh
zig build          # builds timex-mcp, timex-store, and the Native app
zig build mcp      # builds only the standalone MCP/store binaries
zig build app      # builds only the Native app via `native build app`
zig build run      # runs the Native app with the MCP server sidecar
zig build test     # runs MCP/store tests and Native app tests
```

The root MCP binaries install to `zig-out/bin/timex-mcp` and `zig-out/bin/timex-store`.
Native app artifacts are produced by the Native CLI under `app/zig-out/`.

## Runtime

- Set `TIMEX_DB_PATH=/path/to/timex.sqlite` to use a specific SQLite database.
- Set `TIMEX_STORE_BIN=/path/to/timex-store` when launching the app from a working directory where `zig-out/bin/timex-store` is not available.
- MCP clients should launch `zig-out/bin/timex-mcp`.

## Use Timex with a coding agent

Timex is a local stdio MCP server. Build it before starting an agent:

```sh
zig build mcp
```

The repository includes a project-local Codex configuration at `.codex/config.toml`:

```toml
[mcp_servers.timex]
command = "zig-out/bin/timex-mcp"
startup_timeout_sec = 10
tool_timeout_sec = 30
```

Start Codex from the repository root so the relative command resolves to the freshly built binary:

```sh
codex
```

You can verify the server from Codex with a prompt such as:

> Use Timex to create a project named `Codex test`, create a timer named `MCP smoke test` in it, start the timer, and report the resulting IDs and state.

For a disposable test database, set `TIMEX_DB_PATH` before launching Codex:

```sh
TIMEX_DB_PATH=/tmp/timex-codex-test.sqlite codex
```

To add Timex to another coding agent, use its stdio MCP configuration and point `command` at the built binary. The command must run with the repository root as its working directory, or use an absolute path:

```json
{
  "mcpServers": {
    "timex": {
      "command": "/absolute/path/to/timex/zig-out/bin/timex-mcp",
      "env": {
        "TIMEX_DB_PATH": "/absolute/path/to/timex.sqlite"
      }
    }
  }
}
```

Use the equivalent `mcpServers.timex` entry for agents whose configuration is TOML or YAML. Keep the server on stdio; it does not expose an HTTP endpoint. The available tools and resources are documented in [`skills/timex-agent/SKILL.md`](skills/timex-agent/SKILL.md).
