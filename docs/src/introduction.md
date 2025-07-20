# Zuki Async Runtime

Welcome to **Zuki**, a high-performance async runtime for Zig that's fast, cross-platform, and zero-cost.

## What is Zuki?

Zuki is an async runtime that brings structured concurrency to Zig applications. Perfect for developers looking for Zig async programming, concurrent task execution, and high-performance async patterns.

Key capabilities:
- **Task-based execution** - Lightweight, composable async tasks
- **Future/Poll pattern** - Similar to Rust's async model, adapted for Zig
- **Lock-free data structures** - High-performance concurrent collections  
- **Work stealing** - Load balancing across threads
- **Zero-cost abstractions** - Pay only for what you use

## Key Features

### **High Performance**
- Lock-free queues and ring buffers
- Work-stealing scheduler
- Minimal allocation overhead
- Cache-friendly data structures

### **Zero-Cost Abstractions**
- Compile-time optimizations
- No hidden allocations
- Predictable performance
- Optional features

### **Cross-Platform**
- Windows, Linux, macOS support
- Consistent behavior across platforms
- Native threading primitives

## Quick Example

```zig
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

**Early Development**: Zuki is currently in active development with verbose APIs that require significant boilerplate. APIs will change frequently without notice. Not recommended for production use.

## Getting Started

Ready to dive in? Head over to the [Installation](./installation.md) guide to get Zuki set up in your project.
