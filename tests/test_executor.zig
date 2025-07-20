const std = @import("std");
const testing = std.testing;
const zuki = @import("zuki");
const SingleThreadedExecutor = zuki.SingleThreadedExecutor;
const Task = zuki.Task;
const Poll = zuki.Poll;
const Context = zuki.Context;
const Waker = zuki.Waker;

// Test futures for executor testing
const ImmediatelyReadyFuture = struct {
    const Self = @This();
    completed: bool = false,

    pub fn poll(self: *Self, ctx: Context) Poll(void) {
        _ = ctx;
        if (!self.completed) {
            self.completed = true;
            return Poll(void){ .Ready = {} };
        }
        return Poll(void){ .Ready = {} };
    }
};

const DelayedReadyFuture = struct {
    const Self = @This();
    polls_needed: u32,
    current_polls: u32 = 0,
    waker: ?Waker = null,

    pub fn poll(self: *Self, ctx: Context) Poll(void) {
        self.current_polls += 1;
        if (self.current_polls >= self.polls_needed) {
            return Poll(void){ .Ready = {} };
        } else {
            // Store the waker and simulate async notification
            self.waker = ctx.waker;
            return Poll(void){ .Pending = {} };
        }
    }

    pub fn trigger_wake(self: *Self) void {
        if (self.waker) |waker| {
            waker.wake();
        }
    }
};

const NeverReadyFuture = struct {
    const Self = @This();
    poll_count: u32 = 0,

    pub fn poll(self: *Self, ctx: Context) Poll(void) {
        _ = ctx;
        self.poll_count += 1;
        return Poll(void){ .Pending = {} };
    }
};

test "SingleThreadedExecutor - basic creation and cleanup" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    // Check initial state
    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 0);
    try testing.expect(!executor.is_running);
    try testing.expect(executor.next_task_id == 0);
}

test "SingleThreadedExecutor - spawn single ready task" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    var future = ImmediatelyReadyFuture{};
    const task = Task.from_future(&future, 0);

    const handle = try executor.spawn(task);
    try testing.expect(handle.id == 0);
    try testing.expect(executor.ready_tasks.count() == 1);
    try testing.expect(executor.next_task_id == 1);
}

test "SingleThreadedExecutor - spawn multiple tasks" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    // Spawn multiple tasks
    var futures: [5]ImmediatelyReadyFuture = undefined;
    for (0..5) |i| {
        futures[i] = ImmediatelyReadyFuture{};
        const task = Task.from_future(&futures[i], 0);
        const handle = try executor.spawn(task);
        try testing.expect(handle.id == i);
    }

    try testing.expect(executor.ready_tasks.count() == 5);
    try testing.expect(executor.next_task_id == 5);
}

test "SingleThreadedExecutor - isEmpty check" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    // Initially should be empty
    try testing.expect(executor.isEmpty());

    // Spawn a task
    var future = ImmediatelyReadyFuture{};
    const task = Task.from_future(&future, 0);
    _ = try executor.spawn(task);

    // Now should not be empty
    try testing.expect(!executor.isEmpty());

    // Run the executor to complete the task
    try executor.run();

    // After running, should be empty again
    try testing.expect(executor.isEmpty());
}

test "SingleThreadedExecutor - run single ready task" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    var future = ImmediatelyReadyFuture{};
    const task = Task.from_future(&future, 0);
    _ = try executor.spawn(task);

    // Run the executor
    try executor.run();

    // After running, all ready tasks should be completed and removed
    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(future.completed);
}

test "SingleThreadedExecutor - run multiple ready tasks" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    var futures: [10]ImmediatelyReadyFuture = undefined;
    for (0..10) |i| {
        futures[i] = ImmediatelyReadyFuture{};
        const task = Task.from_future(&futures[i], 0);
        _ = try executor.spawn(task);
    }

    try executor.run();

    // All tasks should be completed
    try testing.expect(executor.ready_tasks.count() == 0);
    for (futures) |future| {
        try testing.expect(future.completed);
    }
}

test "SingleThreadedExecutor - step execution" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    var futures: [3]ImmediatelyReadyFuture = undefined;
    for (0..3) |i| {
        futures[i] = ImmediatelyReadyFuture{};
        const task = Task.from_future(&futures[i], 0);
        _ = try executor.spawn(task);
    }

    // Step through execution
    var completed_count: u32 = 0;
    while (try executor.step()) {
        completed_count += 1;
        if (completed_count > 10) break; // Safety valve
    }

    // All tasks should be completed
    try testing.expect(executor.ready_tasks.count() == 0);
    for (futures) |future| {
        try testing.expect(future.completed);
    }
}

test "SingleThreadedExecutor - pending task handling" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    var never_ready = NeverReadyFuture{};
    const task = Task.from_future(&never_ready, 0);
    _ = try executor.spawn(task);

    // Step once - task should go to pending
    const has_more = try executor.step();
    try testing.expect(!has_more); // No more ready tasks
    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 1);
    try testing.expect(never_ready.poll_count == 1);
}

test "SingleThreadedExecutor - wake mechanism" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    var delayed_future = DelayedReadyFuture{ .polls_needed = 2 };
    const task = Task.from_future(&delayed_future, 0);
    const handle = try executor.spawn(task);

    // First step - should go to pending
    const has_more1 = try executor.step();
    try testing.expect(!has_more1);
    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 1);

    // Manually wake the task
    try executor.wake(handle.id);

    // Now should have a ready task again
    try testing.expect(executor.ready_tasks.count() == 1);
    try testing.expect(executor.pending_tasks.items.len == 0);

    // Second step - should complete
    const has_more2 = try executor.step();
    try testing.expect(!has_more2);
    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(delayed_future.current_polls == 2);
}

test "SingleThreadedExecutor - waker integration" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    var delayed_future = DelayedReadyFuture{ .polls_needed = 2 };
    const task = Task.from_future(&delayed_future, 0);
    _ = try executor.spawn(task);

    // First step - task gets waker and goes pending
    _ = try executor.step();
    try testing.expect(executor.pending_tasks.items.len == 1);
    try testing.expect(delayed_future.waker != null);

    // Trigger wake through the stored waker
    delayed_future.trigger_wake();

    // Task should be back in ready queue
    try testing.expect(executor.ready_tasks.count() == 1);
    try testing.expect(executor.pending_tasks.items.len == 0);
}

test "SingleThreadedExecutor - spawn_future convenience method" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    var future = ImmediatelyReadyFuture{};
    const handle = try executor.spawn_future(&future);

    try testing.expect(handle.id == 0);
    try testing.expect(executor.ready_tasks.count() == 1);
}

test "SingleThreadedExecutor - mixed ready and pending tasks" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    // Spawn mix of ready and pending tasks
    var ready_futures: [3]ImmediatelyReadyFuture = undefined;
    var pending_futures: [2]NeverReadyFuture = undefined;

    // Spawn ready tasks
    for (0..3) |i| {
        ready_futures[i] = ImmediatelyReadyFuture{};
        _ = try executor.spawn_future(&ready_futures[i]);
    }

    // Spawn pending tasks
    for (0..2) |i| {
        pending_futures[i] = NeverReadyFuture{};
        _ = try executor.spawn_future(&pending_futures[i]);
    }

    // Run executor - should complete ready tasks, leave pending ones
    try executor.run();

    // Ready tasks should be completed and removed
    for (ready_futures) |future| {
        try testing.expect(future.completed);
    }

    // Pending tasks should be in pending queue
    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 2);

    // Each pending task should have been polled once
    for (pending_futures) |future| {
        try testing.expect(future.poll_count == 1);
    }
}

test "SingleThreadedExecutor - error handling for already running" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    // Manually set running state
    executor.is_running = true;

    // Should get error when trying to run again
    try testing.expectError(error.AlreadyRunning, executor.run());
}

test "SingleThreadedExecutor - wake non-existent task" {
    const allocator = testing.allocator;

    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    // Wake a task that doesn't exist - should not crash
    try executor.wake(999);

    // State should remain unchanged
    try testing.expect(executor.ready_tasks.count() == 0);
    try testing.expect(executor.pending_tasks.items.len == 0);
}
