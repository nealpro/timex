const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mcp_mod = b.createModule(.{
        .root_source_file = b.path("mcp/src/mcp_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(mcp_mod);

    const store_mod = b.createModule(.{
        .root_source_file = b.path("mcp/src/store.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(store_mod);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("mcp/src/store_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(cli_mod);

    const mcp = b.addExecutable(.{ .name = "timex-mcp", .root_module = mcp_mod });
    const cli = b.addExecutable(.{ .name = "timex-store", .root_module = cli_mod });
    const install_mcp = b.addInstallArtifact(mcp, .{});
    const install_cli = b.addInstallArtifact(cli, .{});
    b.getInstallStep().dependOn(&install_mcp.step);
    b.getInstallStep().dependOn(&install_cli.step);

    const native_build = b.addSystemCommand(&.{ "native", "build", "app", "--yes" });
    b.getInstallStep().dependOn(&native_build.step);

    const mcp_step = b.step("mcp", "Build the standalone MCP/store package");
    mcp_step.dependOn(&install_mcp.step);
    mcp_step.dependOn(&install_cli.step);

    const app_step = b.step("app", "Build the Native app package");
    app_step.dependOn(&native_build.step);

    const run_command = b.addSystemCommand(&.{
        "sh",
        "-c",
        "timex_mcp_pid=\"\"\n" ++
        "trap 'if [ -n \"$timex_mcp_pid\" ]; then kill \"$timex_mcp_pid\" 2>/dev/null || true; wait \"$timex_mcp_pid\" 2>/dev/null || true; fi' EXIT INT TERM\n" ++
        "zig-out/bin/timex-mcp </dev/null >/dev/null 2>&1 &\n" ++
        "timex_mcp_pid=$!\n" ++
        "native dev app --yes\n",
    });
    run_command.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the Native app with the MCP server");
    run_step.dependOn(&run_command.step);

    const tests = b.addTest(.{ .root_module = store_mod });
    const run_tests = b.addRunArtifact(tests);
    const native_test = b.addSystemCommand(&.{ "native", "test", "app", "--yes" });

    const test_step = b.step("test", "Run MCP and app tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&native_test.step);
}

fn linkSqlite(module: *std.Build.Module) void {
    module.linkSystemLibrary("c", .{});
    if (module.resolved_target.?.result.os.tag == .macos) {
        module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        module.addIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.0.sdk/usr/include" });
    }
    module.linkSystemLibrary("sqlite3", .{});
}
