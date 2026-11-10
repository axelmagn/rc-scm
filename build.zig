const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("scm", .{
        .root_source_file = b.path("scm.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "scm",
        .root_module = mod,
    });
    b.installArtifact(exe);
    const exe_run = b.addRunArtifact(exe);
    const run_step = b.step("run", "run executable");
    run_step.dependOn(&exe_run.step);

    const mod_test = b.addTest(.{ .root_module = mod });
    const mod_test_run = b.addRunArtifact(mod_test);

    const test_step = b.step("test", "run tests");
    test_step.dependOn(&mod_test_run.step);
}
