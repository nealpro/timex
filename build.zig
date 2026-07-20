//! App-owned build: extends Native's standard app graph with SQLite and a
//! stdio MCP sidecar.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("native_sdk", .{});
    const artifacts = native_sdk.addAppArtifacts(b, dep, .{ .name = "timex" });
    linkSqlite(artifacts.exe);
    linkSqlite(artifacts.tests);

    const target = b.graph.host;
    const optimize: std.builtin.OptimizeMode = .Debug;
    const mcp_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mcp = b.addExecutable(.{ .name = "timex-mcp", .root_module = mcp_mod });
    linkSqlite(mcp);
    b.installArtifact(mcp);
}

fn linkSqlite(step: *std.Build.Step.Compile) void {
    step.root_module.linkSystemLibrary("c", .{});
    if (step.rootModuleTarget().os.tag == .macos) {
        step.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        step.root_module.addIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.0.sdk/usr/include" });
    }
    step.root_module.linkSystemLibrary("sqlite3", .{});
}
