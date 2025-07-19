# Installation

## Requirements

- **Zig 0.14.x** - Zuki is built and tested with Zig 0.14
- **Supported Platforms**: Windows, Linux, macOS (x86_64, ARM64)

## Using Zig Package Manager

Add Zuki to your `build.zig.zon`:

```rust
.{
    .name = "my-project",
    .version = "0.1.0",
    .dependencies = .{
        .zuki = .{
            .url = "https://github.com/yourusername/zuki-async/archive/main.tar.gz",
            .hash = "1234567890abcdef...", // Use actual hash
        },
    },
}
```

Then in your `build.zig`:

```rust
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zuki = b.dependency("zuki", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    exe.root_module.addImport("zuki", zuki.module("zuki"));
    
    b.installArtifact(exe);
}
```

## Manual Installation

1. Clone the repository:
```bash
git clone https://github.com/yourusername/zuki-async.git
```

2. Add as a Git submodule to your project:
```bash
git submodule add https://github.com/yourusername/zuki-async.git deps/zuki
```

3. In your `build.zig`:
```rust
const zuki = b.addModule("zuki", .{
    .root_source_file = b.path("deps/zuki/src/root.zig"),
});

exe.root_module.addImport("zuki", zuki);
```

## Verification

Create a simple test file to verify installation:

```rust
// test.zig
const std = @import("std");
const zuki = @import("zuki");

test "zuki installation" {
    std.debug.print("Zuki version: async runtime for Zig\n", .{});
    
    // Test basic types are available
    _ = zuki.Task;
    _ = zuki.Poll;
    _ = zuki.Context;
    _ = zuki.SingleThreadedExecutor;
}
```

Run with:
```bash
zig test test.zig
```

If you see the version message and no errors, you're ready to go!

## Next Steps

- Check out the [Quick Start](./quick-start.md) guide
- Learn about [Basic Concepts](./concepts.md)
- Browse the [Examples](./examples/simple-tasks.md)
