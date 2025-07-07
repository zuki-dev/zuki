const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zuki",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    // Executor test example
    const executor_test = b.addExecutable(.{
        .name = "executor_test",
        .root_source_file = b.path("src/examples/executor_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    executor_test.root_module.addImport("zuki", lib_mod);

    const run_executor_test = b.addRunArtifact(executor_test);
    run_executor_test.step.dependOn(b.getInstallStep());

    const executor_test_step = b.step("executor-test", "Run the executor test example");
    executor_test_step.dependOn(&run_executor_test.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
