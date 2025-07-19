# Zuki Async Runtime

Welcome to **Zuki**, a high-performance async runtime for Zig designed to be fast, cross-platform, and zero-cost by design.

## What is Zuki?

Zuki is an async runtime that brings structured concurrency to Zig applications. It provides:

- **Task-based execution** - Lightweight, composable async tasks
- **Future/Poll pattern** - Similar to Rust's async model but optimized for Zig
- **Lock-free data structures** - High-performance concurrent collections
- **Work stealing** - Efficient load balancing across threads
- **Zero-cost abstractions** - Pay only for what you use

## Key Features

### 🚀 **High Performance**
- Lock-free queues and ring buffers
- Work-stealing scheduler
- Minimal allocation overhead
- Cache-friendly data structures

### 🎯 **Zero-Cost Abstractions**
- Compile-time optimizations
- No hidden allocations
- Predictable performance
- Optional features

### 🔧 **Developer Friendly**
- Clean, composable API
- Comprehensive error handling
- Extensive documentation
- Rich examples

### 🌐 **Cross-Platform**
- Windows, Linux, macOS support
- Consistent behavior across platforms
- Native threading primitives

## Quick Example

```rust
const std = @import("std");
const zuki = @import("zuki");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    var executor = try zuki.SingleThreadedExecutor.init(gpa.allocator());
    defer executor.deinit();
    
    // Create a simple async task
    var task = MyTask{};
    _ = try executor.spawn_future(&task);
    
    // Run until completion
    try executor.run();
}

const MyTask = struct {
    pub fn poll(self: *@This(), ctx: zuki.Context) zuki.Poll(void) {
        _ = self;
        _ = ctx;
        std.debug.print("Hello from async task!\n", .{});
        return zuki.Poll(void){ .Ready = {} };
    }
};
```

## Project Status

⚠️ **Early Development**: Zuki is currently in active development. APIs may change without notice. Use at your own risk for production workloads.

## Getting Started

Ready to dive in? Head over to the [Installation](./installation.md) guide to get Zuki set up in your project.
