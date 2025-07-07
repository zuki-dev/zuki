const std = @import("std");
const testing = std.testing;
const zuki = @import("zuki");

// Import all the core components
const Task = zuki.Task;
const Poll = zuki.Poll;
const Context = zuki.Context;
const Waker = zuki.Waker;
const TaskPriority = zuki.TaskPriority;
const ready = zuki.ready;
const SingleThreadedExecutor = zuki.SingleThreadedExecutor;

// Complex test futures that simulate real-world scenarios
const TimerFuture = struct {
    const Self = @This();
    target_ticks: u32,
    current_ticks: u32 = 0,
    waker: ?Waker = null,

    pub fn poll(self: *Self, ctx: Context) Poll(u32) {
        self.current_ticks += 1;
        if (self.current_ticks >= self.target_ticks) {
            return Poll(u32){ .Ready = self.current_ticks };
        } else {
            self.waker = ctx.waker;
            return Poll(u32){ .Pending = {} };
        }
    }

    pub fn tick(self: *Self) void {
        if (self.waker) |waker| {
            waker.wake();
        }
    }
};

const ChainedFuture = struct {
    const Self = @This();
    stage: u32 = 0,
    max_stages: u32,
    waker: ?Waker = null,

    pub fn poll(self: *Self, ctx: Context) Poll(u32) {
        self.stage += 1;
        if (self.stage >= self.max_stages) {
            return Poll(u32){ .Ready = self.stage };
        } else {
            self.waker = ctx.waker;
            return Poll(u32){ .Pending = {} };
        }
    }

    pub fn advance(self: *Self) void {
        if (self.waker) |waker| {
            waker.wake();
        }
    }
};

const CountdownFuture = struct {
    const Self = @This();
    remaining: u32,
    waker: ?Waker = null,

    pub fn poll(self: *Self, ctx: Context) Poll(void) {
        if (self.remaining == 0) {
            return Poll(void){ .Ready = {} };
        } else {
            self.remaining -= 1;
            self.waker = ctx.waker;
            return Poll(void){ .Pending = {} };
        }
    }

    pub fn trigger(self: *Self) void {
        if (self.waker) |waker| {
            waker.wake();
        }
    }
};

test "Integration - simple task lifecycle" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    // Create a simple ready future
    var ready_future = ready(i32, 42);
    const task = Task.from_future(&ready_future, 0);
    const handle = try executor.spawn(task);

    try testing.expect(handle.id == 0);
    try testing.expect(executor.ready_tasks.count() == 1);

    // Run and verify completion
    try executor.run();
    try testing.expect(executor.ready_tasks.count() == 0);
}

test "Integration - multiple async tasks with waker coordination" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    // Create multiple countdown futures with different requirements
    var countdown1 = CountdownFuture{ .remaining = 2 };
    var countdown2 = CountdownFuture{ .remaining = 3 };
    var countdown3 = CountdownFuture{ .remaining = 1 };

    const task1 = Task.from_future(&countdown1, 0);
    const task2 = Task.from_future(&countdown2, 0);
    const task3 = Task.from_future(&countdown3, 0);

    const handle1 = try executor.spawn(task1);
    const handle2 = try executor.spawn(task2);
    const handle3 = try executor.spawn(task3);

    // Initial step - all should go pending
    _ = try executor.step();
    _ = try executor.step();
    _ = try executor.step();

    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 3);

    // Complete countdown3 first (needs 1 trigger)
    countdown3.trigger();
    try testing.expect(executor.ready_tasks.count() == 1);
    _ = try executor.step(); // Complete countdown3
    try testing.expect(executor.pending_tasks.items.len == 2);

    // Complete countdown1 next (needs 2 triggers total, already had 1 poll)
    countdown1.trigger();
    _ = try executor.step(); // Second poll
    countdown1.trigger();
    _ = try executor.step(); // Complete countdown1
    try testing.expect(executor.pending_tasks.items.len == 1);

    // Complete countdown2 last (needs 3 triggers total, already had 1 poll)
    countdown2.trigger();
    _ = try executor.step(); // Second poll
    countdown2.trigger();
    _ = try executor.step(); // Third poll
    countdown2.trigger();
    _ = try executor.step(); // Complete countdown2

    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 0);

    _ = handle1;
    _ = handle2;
    _ = handle3;
}

test "Integration - task completion order verification" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    var completion_order: [3]u32 = undefined;
    var completion_index: u32 = 0;

    const CompletionTracker = struct {
        id: u32,
        countdown: *CountdownFuture,
        order: *[3]u32,
        index: *u32,

        pub fn poll(self: @This(), ctx: Context) Poll(void) {
            const result = self.countdown.poll(ctx);
            return switch (result) {
                .Ready => {
                    self.order[self.index.*] = self.id;
                    self.index.* += 1;
                    return Poll(void){ .Ready = {} };
                },
                .Pending => Poll(void){ .Pending = {} },
            };
        }
    };

    var countdown1 = CountdownFuture{ .remaining = 2 };
    var countdown2 = CountdownFuture{ .remaining = 1 };
    var countdown3 = CountdownFuture{ .remaining = 3 };

    var tracker1 = CompletionTracker{ .id = 1, .countdown = &countdown1, .order = &completion_order, .index = &completion_index };
    var tracker2 = CompletionTracker{ .id = 2, .countdown = &countdown2, .order = &completion_order, .index = &completion_index };
    var tracker3 = CompletionTracker{ .id = 3, .countdown = &countdown3, .order = &completion_order, .index = &completion_index };

    _ = try executor.spawn_future(&tracker1);
    _ = try executor.spawn_future(&tracker2);
    _ = try executor.spawn_future(&tracker3);

    // Run initial polls - all should go pending
    _ = try executor.step();
    _ = try executor.step();
    _ = try executor.step();

    // trigger completion in order: 2 -> 1 -> 3
    countdown2.trigger(); // countdown2 remaining = 0, should complete
    _ = try executor.step();

    countdown1.trigger(); // countdown1 remaining = 1
    _ = try executor.step();
    countdown1.trigger(); // countdown1 remaining = 0, should complete
    _ = try executor.step();

    countdown3.trigger(); // countdown3 remaining = 2
    _ = try executor.step();
    countdown3.trigger(); // countdown3 remaining = 1
    _ = try executor.step();
    countdown3.trigger(); // countdown3 remaining = 0, should complete
    _ = try executor.step();

    // Verify completion order
    try testing.expect(completion_order[0] == 2);
    try testing.expect(completion_order[1] == 1);
    try testing.expect(completion_order[2] == 3);
}

test "Integration - mixed ready and pending task execution" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    const ImmediatelyReady = struct {
        value: i32,

        pub fn poll(self: @This(), ctx: Context) Poll(void) {
            _ = ctx;
            _ = self;
            return Poll(void){ .Ready = {} };
        }
    };

    // Mix of immediately ready and pending tasks
    var ready_tasks: [3]ImmediatelyReady = undefined;
    var pending_tasks: [2]CountdownFuture = undefined;

    for (0..3) |i| {
        ready_tasks[i] = ImmediatelyReady{ .value = @intCast(i) };
        _ = try executor.spawn_future(&ready_tasks[i]);
    }

    for (0..2) |i| {
        pending_tasks[i] = CountdownFuture{ .remaining = 2 };
        _ = try executor.spawn_future(&pending_tasks[i]);
    }

    // Run initial execution - ready tasks should complete
    try executor.run();

    // Should have no ready tasks, but pending tasks remain
    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 2);

    // Complete pending tasks
    for (&pending_tasks) |*pending| {
        pending.trigger();
        _ = try executor.step();
        pending.trigger();
        _ = try executor.step();
    }

    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 0);
}

test "Integration - waker stress test" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    // Create many tasks that need to be woken
    var futures: [20]CountdownFuture = undefined;
    for (0..20) |i| {
        futures[i] = CountdownFuture{ .remaining = 1 };
        _ = try executor.spawn_future(&futures[i]);
    }

    // Initial step to get all tasks pending
    for (0..20) |_| {
        _ = try executor.step();
    }

    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 20);

    // Wake all tasks simultaneously
    for (&futures) |*future| {
        future.trigger();
    }

    try testing.expect(executor.ready_tasks.count() == 20);
    try testing.expect(executor.pending_tasks.items.len == 0);

    // Complete all tasks
    try executor.run();

    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 0);
}

test "Integration - priority ordering (simulated)" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    // Create tasks with different implicit priorities based on spawn order
    // Since we're using a priority queue, this tests the ordering
    var tasks_data: [5]CountdownFuture = undefined;
    var handles: [5]zuki.TaskHandle = undefined;

    for (0..5) |i| {
        tasks_data[i] = CountdownFuture{ .remaining = 1 };
        handles[i] = try executor.spawn_future(&tasks_data[i]);
        // Each task gets a sequential ID starting from 0
        try testing.expect(handles[i].id == i);
    }

    // All tasks are ready initially, priority queue should maintain order
    try testing.expect(executor.ready_tasks.count() == 5);

    // Step through and verify tasks are processed
    for (0..5) |_| {
        const has_more = try executor.step();
        _ = has_more;
    }

    // All should be pending now
    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 5);

    // Wake all and complete
    for (&tasks_data) |*task| {
        task.trigger();
    }

    try executor.run();

    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 0);
}

test "Integration - error resilience" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    // Test that executor handles edge cases gracefully

    // 1. Wake non-existent task
    try executor.wake(999);
    try testing.expect(executor.ready_tasks.count() == 0);

    // 2. Step with no tasks
    const has_tasks = try executor.step();
    try testing.expect(!has_tasks);

    // 3. Run with no tasks
    try executor.run();

    // 4. Prevent double-running
    executor.is_running = true;
    try testing.expectError(error.AlreadyRunning, executor.run());
    executor.is_running = false;

    // 5. Normal operation after errors
    var countdown = CountdownFuture{ .remaining = 1 };
    _ = try executor.spawn_future(&countdown);
    _ = try executor.step(); // Should go pending
    countdown.trigger();
    try executor.run(); // Should complete

    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 0);
}
