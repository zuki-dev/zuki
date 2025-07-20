const std = @import("std");
const core = @import("../core/mod.zig");
const Timer = @import("timer.zig").Timer;

const Poll = core.Poll;
const PollState = core.PollState;
const Future = core.Future;
const Waker = core.Waker;
const Context = core.Context;

/// Error types for timeout operations
pub const TimeoutError = error{
    Timeout,
};

/// A future that wraps another future with a timeout
pub fn TimeoutFuture(comptime T: type) type {
    return struct {
        const Self = @This();
        const ResultType = TimeoutError!T;

        inner_future: Future(T),
        deadline: i128,
        timer_id: ?u64,
        timer: *Timer,
        completed: bool,

        /// Create a new TimeoutFuture that wraps the given future with a timeout
        pub fn create(timer: *Timer, future: Future(T), timeout_ns: i128) Self {
            const now = std.time.nanoTimestamp();
            return Self{
                .inner_future = future,
                .deadline = now + timeout_ns,
                .timer_id = null,
                .timer = timer,
                .completed = false,
            };
        }

        /// Create a TimeoutFuture with timeout in milliseconds
        pub fn from_millis(timer: *Timer, future: Future(T), millis: u64) Self {
            return create(timer, future, @intCast(millis * std.time.ns_per_ms));
        }

        /// Create a TimeoutFuture with timeout in seconds
        pub fn from_secs(timer: *Timer, future: Future(T), secs: u64) Self {
            return create(timer, future, @intCast(secs * std.time.ns_per_s));
        }

        /// Poll method for timeout future
        pub fn poll(self: *Self, ctx: Context) Poll(ResultType) {
            // If already completed, don't poll again
            if (self.completed) {
                return Poll(ResultType){ .Pending = {} }; // This shouldn't happen in normal usage
            }

            const now = std.time.nanoTimestamp();

            // Check if we've timed out
            if (now >= self.deadline) {
                self.completed = true;
                // Clean up timer registration if it exists
                if (self.timer_id) |id| {
                    self.timer.remove(id);
                    self.timer_id = null;
                }
                return Poll(ResultType){ .Ready = TimeoutError.Timeout };
            }

            // Poll the inner future first
            const inner_result = self.inner_future.poll(ctx);
            switch (inner_result) {
                .Ready => |value| {
                    self.completed = true;
                    // Clean up timer registration if it exists
                    if (self.timer_id) |id| {
                        self.timer.remove(id);
                        self.timer_id = null;
                    }
                    return Poll(ResultType){ .Ready = value };
                },
                .Pending => {
                    // Register with timer if we haven't already
                    if (self.timer_id == null) {
                        self.timer_id = self.timer.register(self.deadline, ctx.waker) catch |err| {
                            // If we can't register with the timer, treat as timeout to avoid hanging
                            std.log.warn("Failed to register timeout with timer: {}\n", .{err});
                            self.completed = true;
                            return Poll(ResultType){ .Ready = TimeoutError.Timeout };
                        };
                    }
                    return Poll(ResultType){ .Pending = {} };
                },
            }
        }

        /// Convert to a generic Future
        pub fn as_future(self: *Self) Future(ResultType) {
            const vtable = &VTable{
                .poll = pollImpl,
                .deinit = deinitImpl,
            };

            return Future(ResultType){
                .vtable = vtable,
                .ptr = self,
            };
        }

        const VTable = Future(ResultType).VTable;

        fn pollImpl(ptr: *anyopaque, ctx: Context) Poll(ResultType) {
            const self: *TimeoutFuture(T) = @ptrCast(@alignCast(ptr));
            return self.poll(ctx);
        }

        fn deinitImpl(ptr: *anyopaque) void {
            const self: *TimeoutFuture(T) = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        /// Clean up any timer registration
        pub fn deinit(self: *Self) void {
            if (self.timer_id) |id| {
                self.timer.remove(id);
                self.timer_id = null;
            }
        }
    };
}

/// Convenience function to create a timeout future from milliseconds
pub fn timeout_millis(comptime T: type, timer: *Timer, future: Future(T), millis: u64) TimeoutFuture(T) {
    return TimeoutFuture(T).from_millis(timer, future, millis);
}

/// Convenience function to create a timeout future from seconds
pub fn timeout_secs(comptime T: type, timer: *Timer, future: Future(T), secs: u64) TimeoutFuture(T) {
    return TimeoutFuture(T).from_secs(timer, future, secs);
}

test "TimeoutFuture inner completes first" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    // Create a future that completes immediately
    const ImmediateFuture = struct {
        const Self = @This();

        fn poll_impl(self: *Self, _: Context) Poll(i32) {
            _ = self;
            return Poll(i32){ .Ready = 42 };
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

    var immediate_data = ImmediateFuture{};
    const immediate_future = immediate_data.future();

    // Wrap with a long timeout
    var timeout_future = TimeoutFuture(i32).from_secs(&timer, immediate_future, 10);
    defer timeout_future.deinit();

    // Create a dummy context
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

    // Should complete with the inner future's result
    const result = timeout_future.poll(ctx);
    switch (result) {
        .Ready => |val| {
            if (val) |v| {
                try std.testing.expect(v == 42);
            } else |_| {
                try std.testing.expect(false); // Should not be an error
            }
        },
        .Pending => try std.testing.expect(false),
    }
}

test "TimeoutFuture times out" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    // Create a future that never completes
    const PendingFuture = struct {
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
            _ = ptr; // No cleanup needed
        }
    };

    var pending_data = PendingFuture{};
    const pending_future = pending_data.future();

    // Wrap with a timeout that's already expired
    var timeout_future = TimeoutFuture(i32).create(&timer, pending_future, -1000000); // 1ms ago
    defer timeout_future.deinit();

    // Create a dummy context
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

    // Should timeout
    const result = timeout_future.poll(ctx);
    switch (result) {
        .Ready => |val| {
            if (val) |_| {
                try std.testing.expect(false); // Should be an error
            } else |err| {
                try std.testing.expect(err == TimeoutError.Timeout);
            }
        },
        .Pending => try std.testing.expect(false),
    }
}

test "TimeoutFuture pending and registration" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    // Create a future that never completes
    const PendingFuture = struct {
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
            _ = ptr; // No cleanup needed
        }
    };

    var pending_data = PendingFuture{};
    const pending_future = pending_data.future();

    // Wrap with a long timeout
    var timeout_future = TimeoutFuture(i32).from_secs(&timer, pending_future, 10);
    defer timeout_future.deinit();

    // Create a dummy context
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

    // Should be pending
    const result = timeout_future.poll(ctx);
    switch (result) {
        .Ready => try std.testing.expect(false),
        .Pending => {}, // Success
    }

    // Should have registered with timer
    try std.testing.expect(timeout_future.timer_id != null);
    try std.testing.expect(timer.count() == 1);

    // Polling again should not create another registration
    const result2 = timeout_future.poll(ctx);
    switch (result2) {
        .Ready => try std.testing.expect(false),
        .Pending => {}, // Success
    }
    try std.testing.expect(timer.count() == 1);
}

test "TimeoutFuture convenience functions" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    // Create a dummy future
    const DummyFuture = struct {
        const Self = @This();

        fn poll_impl(self: *Self, _: Context) Poll(void) {
            _ = self;
            return Poll(void){ .Pending = {} };
        }

        fn future(self: *Self) Future(void) {
            const vtable = &VTable{
                .poll = pollVtable,
                .deinit = deinitVtable,
            };
            return Future(void){
                .vtable = vtable,
                .ptr = self,
            };
        }

        const VTable = Future(void).VTable;

        fn pollVtable(ptr: *anyopaque, ctx: Context) Poll(void) {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.poll_impl(ctx);
        }

        fn deinitVtable(ptr: *anyopaque) void {
            _ = ptr; // No cleanup needed
        }
    };

    var dummy_data = DummyFuture{};
    const dummy_future = dummy_data.future();

    const timeout1 = timeout_millis(void, &timer, dummy_future, 100);
    const timeout2 = timeout_secs(void, &timer, dummy_future, 2);

    // Both should be valid TimeoutFuture instances
    try std.testing.expect(timeout1.timer == &timer);
    try std.testing.expect(timeout2.timer == &timer);

    // timeout2 should have a later deadline than timeout1
    try std.testing.expect(timeout2.deadline > timeout1.deadline);
}
