const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const store_mod = b.createModule(.{
        .root_source_file = b.path("src/store.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(store_mod);

    const mcp_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(mcp_mod);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/store_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSqlite(cli_mod);

    const mcp = b.addExecutable(.{ .name = "timex-mcp", .root_module = mcp_mod });
    const cli = b.addExecutable(.{ .name = "timex-store", .root_module = cli_mod });
    b.installArtifact(mcp);
    b.installArtifact(cli);

    const tests = b.addTest(.{ .root_module = store_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run MCP/store tests");
    test_step.dependOn(&run_tests.step);
}

fn linkSqlite(module: *std.Build.Module) void {
    module.linkSystemLibrary("c", .{});
    if (module.resolved_target.?.result.os.tag == .macos) {
        module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        module.addIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.0.sdk/usr/include" });
    }
    module.linkSystemLibrary("sqlite3", .{});
}
