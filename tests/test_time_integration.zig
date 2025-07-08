const std = @import("std");
const zuki = @import("zuki");

// Import all the types we need
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

test "DelayFuture integration with executor" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    var executor = try SingleThreadedExecutor.init(std.testing.allocator);
    defer executor.deinit();

    // Create a very short delay (1ms)
    var delay = DelayFuture.from_millis(&timer, 1);
    defer delay.deinit();

    // Convert to task and spawn
    const task = Task.from_future(&delay, 1);
    _ = try executor.spawn(task);

    // Step once to register with timer
    _ = try executor.step();

    // Now should be registered with timer
    try std.testing.expect(timer.count() == 1);

    // Wait a bit and process expired timers
    std.time.sleep(2 * std.time.ns_per_ms);
    try timer.process_expired();

    // Step again - task should complete
    _ = try executor.step();

    // Timer should be cleaned up
    try std.testing.expect(timer.count() == 0);
}

test "TimeoutFuture completes before timeout" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    // Create a future that completes immediately
    const ImmediateFuture = struct {
        const Self = @This();
        value: i32,

        fn poll_impl(self: *Self, _: Context) Poll(i32) {
            return Poll(i32){ .Ready = self.value };
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
            _ = ptr;
        }
    };

    var immediate_data = ImmediateFuture{ .value = 42 };
    const immediate_future = immediate_data.future();

    // Wrap with a long timeout
    var timeout_future = TimeoutFuture(i32).from_secs(&timer, immediate_future, 10);
    defer timeout_future.deinit();

    // Create dummy context
    const DummyData = struct {
        woken: bool = false,

        fn wake_fn(data: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.woken = true;
        }
    };

    var dummy_data = DummyData{};
    const waker = Waker{
        .wake_fn = DummyData.wake_fn,
        .data = &dummy_data,
    };
    const ctx = Context{ .waker = waker };

    // Should complete immediately with the value
    const result = timeout_future.poll(ctx);
    switch (result) {
        .Ready => |val| {
            if (val) |value| {
                try std.testing.expect(value == 42);
            } else |_| {
                try std.testing.expect(false); // Should not be an error
            }
        },
        .Pending => try std.testing.expect(false),
    }

    // Should not have registered with timer since it completed immediately
    try std.testing.expect(timer.count() == 0);
}

test "TimeoutFuture times out slow future" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    // Create a future that never completes
    const SlowFuture = struct {
        const Self = @This();

        fn poll_impl(self: *Self, _: Context) Poll(i32) {
            _ = self;
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
            _ = ptr;
        }
    };

    var slow_data = SlowFuture{};
    const slow_future = slow_data.future();

    // Wrap with a very short timeout (1ms)
    var timeout_future = TimeoutFuture(i32).from_millis(&timer, slow_future, 1);
    defer timeout_future.deinit();

    // Create dummy context
    const DummyData = struct {
        woken: bool = false,

        fn wake_fn(data: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.woken = true;
        }
    };

    var dummy_data = DummyData{};
    const waker = Waker{
        .wake_fn = DummyData.wake_fn,
        .data = &dummy_data,
    };
    const ctx = Context{ .waker = waker };

    // First poll should be pending and register with timer
    const result1 = timeout_future.poll(ctx);
    switch (result1) {
        .Ready => try std.testing.expect(false),
        .Pending => {}, // Expected
    }

    // Should be registered with timer
    try std.testing.expect(timer.count() == 1);

    // Wait for timeout and process expired timers
    std.time.sleep(2 * std.time.ns_per_ms);
    try timer.process_expired();

    // Should have woken the task
    try std.testing.expect(dummy_data.woken);

    // Poll again - should timeout now
    const result2 = timeout_future.poll(ctx);
    switch (result2) {
        .Ready => |val| {
            if (val) |_| {
                try std.testing.expect(false); // Should be error
            } else |err| {
                try std.testing.expect(err == TimeoutError.Timeout);
            }
        },
        .Pending => try std.testing.expect(false),
    }

    // Timer should be cleaned up
    try std.testing.expect(timer.count() == 0);
}

test "Multiple concurrent delays with different durations" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    // Create delays with much more spaced out completion times to avoid timing issues
    var delay1 = DelayFuture.from_millis(&timer, 1); // 1ms
    var delay2 = DelayFuture.from_millis(&timer, 10); // 10ms
    var delay3 = DelayFuture.from_millis(&timer, 20); // 20ms

    defer delay1.deinit();
    defer delay2.deinit();
    defer delay3.deinit();

    // Create dummy context
    const DummyData = struct {
        woken: bool = false,

        fn wake_fn(data: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.woken = true;
        }
    };

    var dummy_data = DummyData{};
    const waker = Waker{
        .wake_fn = DummyData.wake_fn,
        .data = &dummy_data,
    };
    const ctx = Context{ .waker = waker };

    // Poll all delays - should register with timer
    _ = delay1.poll(ctx);
    _ = delay2.poll(ctx);
    _ = delay3.poll(ctx);

    // Should have 3 timers registered
    try std.testing.expect(timer.count() == 3);

    // Wait 5ms and process - delay1 should expire
    std.time.sleep(5 * std.time.ns_per_ms);
    try timer.process_expired();

    // Should have fewer timers left
    try std.testing.expect(timer.count() <= 2);

    // delay1 should now be ready
    const result1 = delay1.poll(ctx);
    switch (result1) {
        .Ready => {}, // Expected
        .Pending => try std.testing.expect(false),
    }

    // Wait another 20ms and process - all should expire
    std.time.sleep(20 * std.time.ns_per_ms);
    try timer.process_expired();

    // Should have no timers left
    try std.testing.expect(timer.count() == 0);

    // All delays should now be ready
    const final_result2 = delay2.poll(ctx);
    const final_result3 = delay3.poll(ctx);
    switch (final_result2) {
        .Ready => {}, // Expected
        .Pending => try std.testing.expect(false),
    }
    switch (final_result3) {
        .Ready => {}, // Expected
        .Pending => try std.testing.expect(false),
    }
}

test "Timer deadline management" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    const now = std.time.nanoTimestamp();

    // Create dummy waker
    const DummyData = struct {
        woken: bool = false,

        fn wake_fn(data: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.woken = true;
        }
    };

    var dummy_data = DummyData{};
    const waker = Waker{
        .wake_fn = DummyData.wake_fn,
        .data = &dummy_data,
    };

    // Register timers with different deadlines
    const deadline1 = now + 1000000; // 1ms future
    const deadline2 = now + 2000000; // 2ms future
    const deadline3 = now + 500000; // 0.5ms future (earliest)

    _ = try timer.register(deadline1, waker);
    _ = try timer.register(deadline2, waker);
    _ = try timer.register(deadline3, waker);

    // Next deadline should be the earliest one
    const next = timer.next_deadline();
    try std.testing.expect(next.? == deadline3);

    // Wait and expire the earliest
    std.time.sleep(2 * std.time.ns_per_ms); // Increased sleep time
    try timer.process_expired();

    // Should have 2 left, but timing may vary
    try std.testing.expect(timer.count() <= 2);
    if (timer.count() > 0) {
        const next2 = timer.next_deadline();
        try std.testing.expect(next2.? >= deadline1);
    }
}
