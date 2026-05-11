const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_flags = &.{
        "-DSQLITE_THREADSAFE=0",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_DQS=0",
    };

    const exe = b.addExecutable(.{
        .name = "x-bookmarks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = sqlite_flags });
    exe.addIncludePath(b.path("vendor/sqlite"));
    exe.linkLibC();
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = sqlite_flags });
    unit_tests.addIncludePath(b.path("vendor/sqlite"));
    unit_tests.linkLibC();

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
