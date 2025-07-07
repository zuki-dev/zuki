const std = @import("std");
const testing = std.testing;
const zuki = @import("zuki");
const Task = zuki.Task;
const TaskState = zuki.TaskState;
const TaskPriority = zuki.TaskPriority;
const TaskHandle = zuki.TaskHandle;
const Poll = zuki.Poll;
const Context = zuki.Context;
const Waker = zuki.Waker;
const ReadyFuture = zuki.ReadyFuture;
const ready = zuki.ready;
const Future = zuki.Future;

// Test futures for various scenarios
const TestFuture = struct {
    const Self = @This();
    polls_until_ready: u32,
    current_polls: u32 = 0,
    waker_calls: u32 = 0,

    pub fn poll(self: *Self, ctx: Context) Poll(void) {
        self.current_polls += 1;
        if (self.current_polls >= self.polls_until_ready) {
            return Poll(void){ .Ready = {} };
        } else {
            // Store waker for later use
            _ = ctx; // For now, we don't actually call the waker
            return Poll(void){ .Pending = {} };
        }
    }
};

const AlwaysReadyFuture = struct {
    const Self = @This();
    value: i32,

    pub fn poll(self: *Self, ctx: Context) Poll(void) {
        _ = ctx;
        _ = self; // We don't actually use the value in this test
        return Poll(void){ .Ready = {} };
    }
};

const AlwaysPendingFuture = struct {
    const Self = @This();
    poll_count: u32 = 0,

    pub fn poll(self: *Self, ctx: Context) Poll(void) {
        _ = ctx;
        self.poll_count += 1;
        return Poll(void){ .Pending = {} };
    }
};

const CountingFuture = struct {
    const Self = @This();
    target_count: u32,
    current_count: u32 = 0,

    pub fn poll(self: *Self, ctx: Context) Poll(u32) {
        _ = ctx;
        self.current_count += 1;
        if (self.current_count >= self.target_count) {
            return Poll(u32){ .Ready = self.current_count };
        } else {
            return Poll(u32){ .Pending = {} };
        }
    }
};

fn dummyWake(data: *anyopaque) void {
    _ = data;
    // No-op for testing
}

test "Task - basic creation and properties" {
    var test_future = AlwaysReadyFuture{ .value = 42 };
    const task = Task.from_future(&test_future, 123);

    try testing.expect(task.id == 123);
    try testing.expect(task.state == .Ready);
    try testing.expect(task.priority == .Normal);
}

test "Task - from_future with ready future" {
    var ready_future = AlwaysReadyFuture{ .value = 100 };
    var task = Task.from_future(&ready_future, 1);

    // Create a dummy context for polling
    var dummy_data: u8 = 0;
    const waker = Waker.init(dummyWake, &dummy_data);
    const ctx = Context{ .waker = waker };

    // Poll the task
    const result = task.poll(ctx);
    switch (result) {
        .Ready => {}, // Should be ready immediately
        .Pending => try testing.expect(false),
    }
}

test "Task - from_future with pending future" {
    var pending_future = AlwaysPendingFuture{};
    var task = Task.from_future(&pending_future, 2);

    var dummy_data: u8 = 0;
    const waker = Waker.init(dummyWake, &dummy_data);
    const ctx = Context{ .waker = waker };

    // Poll the task multiple times
    const result1 = task.poll(ctx);
    const result2 = task.poll(ctx);

    switch (result1) {
        .Ready => try testing.expect(false),
        .Pending => {}, // Should be pending
    }

    switch (result2) {
        .Ready => try testing.expect(false),
        .Pending => {}, // Should still be pending
    }

    // Verify the future was actually polled
    try testing.expect(pending_future.poll_count == 2);
}

test "Task - from_future with conditional future" {
    var conditional_future = TestFuture{ .polls_until_ready = 3 };
    var task = Task.from_future(&conditional_future, 3);

    var dummy_data: u8 = 0;
    const waker = Waker.init(dummyWake, &dummy_data);
    const ctx = Context{ .waker = waker };

    // First two polls should be pending
    const result1 = task.poll(ctx);
    switch (result1) {
        .Ready => try testing.expect(false),
        .Pending => {},
    }

    const result2 = task.poll(ctx);
    switch (result2) {
        .Ready => try testing.expect(false),
        .Pending => {},
    }

    // Third poll should be ready
    const result3 = task.poll(ctx);
    switch (result3) {
        .Ready => {},
        .Pending => try testing.expect(false),
    }

    try testing.expect(conditional_future.current_polls == 3);
}

test "Task - from_typed_future method" {
    var counting_future = CountingFuture{ .target_count = 2 };
    var task = Task.from_typed_future(u32, &counting_future, 4);

    var dummy_data: u8 = 0;
    const waker = Waker.init(dummyWake, &dummy_data);
    const ctx = Context{ .waker = waker };

    // First poll should be pending
    const result1 = task.poll(ctx);
    switch (result1) {
        .Ready => try testing.expect(false),
        .Pending => {},
    }

    // Second poll should be ready
    const result2 = task.poll(ctx);
    switch (result2) {
        .Ready => {},
        .Pending => try testing.expect(false),
    }

    try testing.expect(counting_future.current_count == 2);
}

test "TaskState enum values" {
    try testing.expect(@intFromEnum(TaskState.Ready) == 0);
    try testing.expect(@intFromEnum(TaskState.Pending) == 1);
    try testing.expect(@intFromEnum(TaskState.Running) == 2);
    try testing.expect(@intFromEnum(TaskState.Completed) == 3);
    try testing.expect(@intFromEnum(TaskState.Failed) == 4);
}

test "TaskPriority enum values and ordering" {
    try testing.expect(@intFromEnum(TaskPriority.Low) == 0);
    try testing.expect(@intFromEnum(TaskPriority.Normal) == 1);
    try testing.expect(@intFromEnum(TaskPriority.High) == 2);
    try testing.expect(@intFromEnum(TaskPriority.Critical) == 3);

    // Test priority comparison
    try testing.expect(@intFromEnum(TaskPriority.Low) < @intFromEnum(TaskPriority.Normal));
    try testing.expect(@intFromEnum(TaskPriority.Normal) < @intFromEnum(TaskPriority.High));
    try testing.expect(@intFromEnum(TaskPriority.High) < @intFromEnum(TaskPriority.Critical));
}

test "TaskHandle structure" {
    const handle = TaskHandle{ .id = 12345 };
    try testing.expect(handle.id == 12345);
}

test "Task - multiple tasks with same future type" {
    var future1 = TestFuture{ .polls_until_ready = 1 };
    var future2 = TestFuture{ .polls_until_ready = 2 };
    var future3 = TestFuture{ .polls_until_ready = 3 };

    var task1 = Task.from_future(&future1, 1);
    var task2 = Task.from_future(&future2, 2);
    var task3 = Task.from_future(&future3, 3);

    var dummy_data: u8 = 0;
    const waker = Waker.init(dummyWake, &dummy_data);
    const ctx = Context{ .waker = waker };

    // Test that each task maintains its own state
    const result1 = task1.poll(ctx);
    const result2_1 = task2.poll(ctx);
    const result3_1 = task3.poll(ctx);

    // task1 should be ready after 1 poll
    switch (result1) {
        .Ready => {},
        .Pending => try testing.expect(false),
    }

    // task2 and task3 should still be pending
    switch (result2_1) {
        .Ready => try testing.expect(false),
        .Pending => {},
    }
    switch (result3_1) {
        .Ready => try testing.expect(false),
        .Pending => {},
    }

    // Poll task2 again - should be ready now
    const result2_2 = task2.poll(ctx);
    switch (result2_2) {
        .Ready => {},
        .Pending => try testing.expect(false),
    }

    // task3 still needs one more poll
    const result3_2 = task3.poll(ctx);
    switch (result3_2) {
        .Ready => try testing.expect(false),
        .Pending => {},
    }

    const result3_3 = task3.poll(ctx);
    switch (result3_3) {
        .Ready => {},
        .Pending => try testing.expect(false),
    }
}

test "ReadyFuture and ready helper function" {
    var ready_int = ready(i32, 42);
    var ready_bool = ready(bool, true);
    var ready_str = ready([]const u8, "hello");

    var dummy_data: u8 = 0;
    const waker = Waker.init(dummyWake, &dummy_data);
    const ctx = Context{ .waker = waker };

    // Test integer ready future
    const int_result = ready_int.poll(ctx);
    switch (int_result) {
        .Ready => |value| try testing.expect(value == 42),
        .Pending => try testing.expect(false),
    }

    // Test boolean ready future
    const bool_result = ready_bool.poll(ctx);
    switch (bool_result) {
        .Ready => |value| try testing.expect(value == true),
        .Pending => try testing.expect(false),
    }

    // Test string ready future
    const str_result = ready_str.poll(ctx);
    switch (str_result) {
        .Ready => |value| try testing.expectEqualStrings(value, "hello"),
        .Pending => try testing.expect(false),
    }
}

test "Task memory and performance characteristics" {
    // Verify that Task struct is reasonably sized
    try testing.expect(@sizeOf(Task) <= 64); // Should be relatively compact

    // Verify alignment requirements
    try testing.expect(@alignOf(Task) <= 8); // Should not have excessive alignment

    // Test that we can create many tasks without issues
    var futures: [100]AlwaysReadyFuture = undefined;
    var tasks: [100]Task = undefined;

    for (0..100) |i| {
        futures[i] = AlwaysReadyFuture{ .value = @intCast(i) };
        tasks[i] = Task.from_future(&futures[i], @intCast(i));
        try testing.expect(tasks[i].id == i);
    }
}
