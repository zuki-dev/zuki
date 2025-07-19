# Quick Start

This guide will get you running your first async task with Zuki in minutes.

## Your First Async Task

Let's create a simple program that runs multiple tasks concurrently:

```rust
const std = @import("std");
const zuki = @import("zuki");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    var executor = try zuki.SingleThreadedExecutor.init(gpa.allocator());
    defer executor.deinit();
    
    std.debug.print("Starting async tasks...\n", .{});
    
    // Create multiple tasks
    var task1 = PrintTask{ .id = 1, .message = "Hello" };
    var task2 = PrintTask{ .id = 2, .message = "World" };
    var task3 = CountTask{ .target = 5 };
    
    // Spawn them
    _ = try executor.spawn_future(&task1);
    _ = try executor.spawn_future(&task2);
    _ = try executor.spawn_future(&task3);
    
    // Run until all tasks complete
    try executor.run();
    
    std.debug.print("All tasks completed!\n", .{});
}

const PrintTask = struct {
    id: u32,
    message: []const u8,
    
    pub fn poll(self: *@This(), ctx: zuki.Context) zuki.Poll(void) {
        _ = ctx;
        std.debug.print("Task {}: {s}\n", .{ self.id, self.message });
        return zuki.Poll(void){ .Ready = {} };
    }
};

const CountTask = struct {
    target: u32,
    current: u32 = 0,
    
    pub fn poll(self: *@This(), ctx: zuki.Context) zuki.Poll(void) {
        if (self.current >= self.target) {
            std.debug.print("Counting complete: {}\n", .{self.current});
            return zuki.Poll(void){ .Ready = {} };
        }
        
        self.current += 1;
        std.debug.print("Count: {}\n", .{self.current});
        
        // Wake ourselves up for the next iteration
        ctx.waker.wake();
        return zuki.Poll(void){ .Pending = {} };
    }
};
```

Save this as `example.zig` and run:
```bash
zig run example.zig
```

You should see output like:
```
Starting async tasks...
Task 1: Hello
Task 2: World
Count: 1
Count: 2
Count: 3
Count: 4
Count: 5
Counting complete: 5
All tasks completed!
```

## Adding Delays

Let's make things more interesting with timing:

```rust
const std = @import("std");
const zuki = @import("zuki");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    var executor = try zuki.SingleThreadedExecutor.init(gpa.allocator());
    defer executor.deinit();
    
    var timer = zuki.Timer.init(gpa.allocator());
    defer timer.deinit();
    
    // Create a task that waits 1 second
    var delay_task = DelayTask{ .timer = &timer };
    _ = try executor.spawn_future(&delay_task);
    
    // Run the executor, processing timers
    while (true) {
        // Process any expired timers
        try timer.process_expired();
        
        // Run one step of the executor
        const has_more = try executor.step();
        if (!has_more) break;
        
        // Short sleep to avoid busy loop
        std.time.sleep(1000000); // 1ms
    }
    
    std.debug.print("All done!\n", .{});
}

const DelayTask = struct {
    timer: *zuki.Timer,
    delay_future: ?zuki.DelayFuture = null,
    
    pub fn poll(self: *@This(), ctx: zuki.Context) zuki.Poll(void) {
        if (self.delay_future == null) {
            std.debug.print("Starting delay...\n", .{});
            self.delay_future = zuki.DelayFuture.from_secs(self.timer, 1);
        }
        
        const result = self.delay_future.?.poll(ctx);
        switch (result) {
            .Ready => {
                std.debug.print("Delay completed!\n", .{});
                return zuki.Poll(void){ .Ready = {} };
            },
            .Pending => return zuki.Poll(void){ .Pending = {} },
        }
    }
};
```

## What's Next?

Great! You've run your first Zuki async tasks. Here's what to explore next:

1. **[Basic Concepts](./concepts.md)** - Understand the fundamentals
2. **[Tasks and Futures](./guide/tasks-futures.md)** - Deep dive into task creation
3. **[Timing and Delays](./guide/timing.md)** - Master timeouts and delays
4. **[Examples](./examples/simple-tasks.md)** - More real-world examples

## Common Patterns

### Error Handling
```rust
const MyTask = struct {
    pub fn poll(self: *@This(), ctx: zuki.Context) zuki.Poll(anyerror!void) {
        _ = self;
        _ = ctx;
        
        // Simulate work that might fail
        if (std.crypto.random.boolean()) {
            return zuki.Poll(anyerror!void){ .Ready = error.SomethingWentWrong };
        }
        
        return zuki.Poll(anyerror!void){ .Ready = {} };
    }
};
```

### Stateful Tasks
```rust
const StatefulTask = struct {
    state: enum { Init, Working, Done } = .Init,
    work_done: u32 = 0,
    
    pub fn poll(self: *@This(), ctx: zuki.Context) zuki.Poll(void) {
        switch (self.state) {
            .Init => {
                std.debug.print("Initializing...\n", .{});
                self.state = .Working;
                ctx.waker.wake();
                return zuki.Poll(void){ .Pending = {} };
            },
            .Working => {
                self.work_done += 1;
                if (self.work_done >= 10) {
                    self.state = .Done;
                    ctx.waker.wake();
                    return zuki.Poll(void){ .Pending = {} };
                }
                ctx.waker.wake();
                return zuki.Poll(void){ .Pending = {} };
            },
            .Done => {
                std.debug.print("Work completed: {}\n", .{self.work_done});
                return zuki.Poll(void){ .Ready = {} };
            },
        }
    }
};
```

Now you're ready to build more complex async applications with Zuki!
