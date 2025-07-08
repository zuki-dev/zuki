const std = @import("std");

/// Find and build all examples in a directory
fn findAndBuildExamples(b: *std.Build, examples_path: []const u8, lib_mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, examples_step: *std.Build.Step) void {
    // Open the examples directory
    var examples_dir = b.build_root.handle.openDir(examples_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Error opening examples directory: {}\n", .{err});
        return;
    };
    defer examples_dir.close();

    // Iterate through files in the directory
    var dir_iter = examples_dir.iterate();
    while (dir_iter.next() catch |err| {
        std.debug.print("Error iterating examples directory: {}\n", .{err});
        return;
    }) |entry| {
        // We only care about .zig files
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) {
            continue;
        }

        // Get the example name without the .zig extension
        const example_name = entry.name[0 .. entry.name.len - 4];

        // Skip files that don't look like examples
        if (std.mem.startsWith(u8, example_name, ".") or
            std.mem.startsWith(u8, example_name, "_"))
        {
            continue;
        }

        const example_path = b.fmt("{s}/{s}", .{ examples_path, entry.name });

        // Create the executable for this example
        const example_exe = b.addExecutable(.{
            .name = example_name,
            .root_source_file = b.path(example_path),
            .target = target,
            .optimize = optimize,
        });

        // Link with the library
        example_exe.root_module.addImport("zuki", lib_mod);

        // Install the example binary
        b.installArtifact(example_exe);

        // Add a run step for this specific example
        const run_example = b.addRunArtifact(example_exe);
        run_example.step.dependOn(b.getInstallStep());

        // Add a step to build and run the specific example
        // This allows `zig build <example_name>`
        const example_step = b.step(example_name, b.fmt("Run the {s} example", .{example_name}));
        example_step.dependOn(&run_example.step);

        // Add this example to the "build all examples" step
        examples_step.dependOn(&example_exe.step);
    }
}

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

    // Create a common step for building all examples
    const examples_step = b.step("ex", "Build all examples");

    // Find and build all examples in the src/examples directory
    findAndBuildExamples(b, "examples", lib_mod, target, optimize, examples_step);

    // Add a unit test step
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Add individual test files
    const test_files = [_][]const u8{
        "tests/test_poll.zig",
        "tests/test_waker.zig",
        "tests/test_task.zig",
        "tests/test_executor.zig",
        "tests/test_integration.zig",
        "tests/test_time_integration.zig",
    };

    for (test_files) |test_file| {
        const test_exe = b.addTest(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        test_exe.root_module.addImport("zuki", lib_mod);

        const run_test = b.addRunArtifact(test_exe);
        run_lib_unit_tests.step.dependOn(&run_test.step);
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Add a default step that builds both the library and all examples
    const default_step = b.getInstallStep();
    default_step.dependOn(examples_step);
}
