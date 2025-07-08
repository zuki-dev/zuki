const std = @import("std");
const zuki = @import("../src/root.zig");

// Import the main types we'll need
const Timer = zuki.Timer;
const DelayFuture = zuki.DelayFuture;
const TimeoutFuture = zuki.TimeoutFuture;
const TimeoutError = zuki.TimeoutError;
const SingleThreadedExecutor = zuki.SingleThreadedExecutor;
const Task = zuki.Task;
const Context = zuki.Context;
const Waker = zuki.Waker;
const Poll = zuki.Poll;
const Future = zuki.Future;

/// Example showing basic delay functionality
pub fn delay_example() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a timer for delay management
    var timer = Timer.init(allocator);
    defer timer.deinit();

    // Create executor
    var executor = SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    std.log.info("Starting delay example...", .{});

    // Create a delay future that will complete after 100ms
    var delay = DelayFuture.from_millis(&timer, 100);
    defer delay.deinit();

    // Convert to task and spawn
    const task = Task.from_future(&delay, 1);
    try executor.spawn(task);

    // Run the executor with timer processing
    var iterations: u32 = 0;
    while (executor.has_ready_tasks() or timer.count() > 0) {
        // Process any expired timers first
        try timer.process_expired();

        // Run one iteration of the executor
        try executor.step();

        iterations += 1;
        if (iterations > 1000) {
            std.log.warn("Breaking after 1000 iterations to avoid infinite loop", .{});
            break;
        }

        // Small sleep to avoid busy waiting
        std.time.sleep(1 * std.time.ns_per_ms);
    }

    std.log.info("Delay completed after {} iterations", .{iterations});
}

/// Example showing timeout functionality
pub fn timeout_example() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a timer for timeout management
    var timer = Timer.init(allocator);
    defer timer.deinit();

    std.log.info("Starting timeout example...", .{});

    // Create a future that never completes (simulates a slow operation)
    const SlowFuture = struct {
        const Self = @This();

        fn poll_impl(self: *Self, _: Context) Poll(i32) {
            _ = self;
            std.log.info("SlowFuture polled - still pending", .{});
            return Poll(i32){ .Pending = {} };
        }

        fn future(self: *Self) Future(i32) {
            const vtable = &VTable{
                .poll = pollVtable,
                .deinit = deinitVtable,
            };
            return Future(i32){
                .vtable = vtable,
                .ptr = self,
            };
        }

        const VTable = Future(i32).VTable;

        fn pollVtable(ptr: *anyopaque, ctx: Context) Poll(i32) {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.poll_impl(ctx);
        }

        fn deinitVtable(ptr: *anyopaque) void {
            _ = ptr; // No cleanup needed
        }
    };

    var slow_future_data = SlowFuture{};
    const slow_future = slow_future_data.future();

    // Wrap with a 50ms timeout
    var timeout_future = TimeoutFuture(i32).from_millis(&timer, slow_future, 50);
    defer timeout_future.deinit();

    // Create a dummy context for testing
    const DummyData = struct {
        woken: bool = false,

        fn wake_fn(data: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.woken = true;
            std.log.info("Waker called!", .{});
        }
    };

    var dummy_data = DummyData{};
    const waker = Waker{
        .wake_fn = DummyData.wake_fn,
        .data = &dummy_data,
    };
    const ctx = Context{ .waker = waker };

    // Poll the timeout future multiple times with timer processing
    var iterations: u32 = 0;
    const max_iterations = 100;

    while (iterations < max_iterations) {
        // Process any expired timers
        try timer.process_expired();

        // Poll the timeout future
        const result = timeout_future.poll(ctx);
        switch (result) {
            .Ready => |val| {
                if (val) |value| {
                    std.log.info("Future completed with value: {}", .{value});
                } else |err| {
                    std.log.info("Future timed out with error: {}", .{err});
                    if (err == TimeoutError.Timeout) {
                        std.log.info("Successfully caught timeout!");
                    }
                }
                break;
            },
            .Pending => {
                // Still waiting
            },
        }

        iterations += 1;
        // Small sleep to simulate time passing
        std.time.sleep(2 * std.time.ns_per_ms);
    }

    if (iterations >= max_iterations) {
        std.log.warn("Example ended without completion - this might indicate an issue", .{});
    }
}

/// Example showing multiple concurrent delays
pub fn concurrent_delays_example() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a timer for delay management
    var timer = Timer.init(allocator);
    defer timer.deinit();

    // Create executor
    var executor = SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    std.log.info("Starting concurrent delays example...", .{});

    // Create multiple delay futures with different durations
    var delay1 = DelayFuture.from_millis(&timer, 30); // 30ms
    var delay2 = DelayFuture.from_millis(&timer, 60); // 60ms
    var delay3 = DelayFuture.from_millis(&timer, 90); // 90ms

    defer delay1.deinit();
    defer delay2.deinit();
    defer delay3.deinit();

    // Convert to tasks and spawn
    const task1 = Task.from_future(&delay1, 1);
    const task2 = Task.from_future(&delay2, 2);
    const task3 = Task.from_future(&delay3, 3);

    try executor.spawn(task1);
    try executor.spawn(task2);
    try executor.spawn(task3);

    std.log.info("Spawned 3 delay tasks (30ms, 60ms, 90ms)", .{});

    // Run the executor with timer processing
    var iterations: u32 = 0;
    var completed_tasks: u32 = 0;
    const initial_task_count = 3;

    while (completed_tasks < initial_task_count and iterations < 1000) {
        const tasks_before = executor.ready_count() + executor.pending_count();

        // Process any expired timers first
        try timer.process_expired();

        // Run one iteration of the executor
        try executor.step();

        const tasks_after = executor.ready_count() + executor.pending_count();
        if (tasks_after < tasks_before) {
            completed_tasks += tasks_before - tasks_after;
            std.log.info("Task completed! Total completed: {}/{}", .{ completed_tasks, initial_task_count });
        }

        iterations += 1;

        // Small sleep to simulate time passing
        std.time.sleep(1 * std.time.ns_per_ms);
    }

    std.log.info("Concurrent delays completed after {} iterations", .{iterations});
}

pub fn main() !void {
    std.log.info("=== Zuki Timeout and Delay Examples ===", .{});

    std.log.info("\n--- Delay Example ---", .{});
    try delay_example();

    std.log.info("\n--- Timeout Example ---", .{});
    try timeout_example();

    std.log.info("\n--- Concurrent Delays Example ---", .{});
    try concurrent_delays_example();

    std.log.info("\n=== All Examples Completed ===", .{});
}
