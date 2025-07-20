const std = @import("std");
const core = @import("../core/mod.zig");
const Timer = @import("timer.zig").Timer;

const Poll = core.Poll;
const PollState = core.PollState;
const Future = core.Future;
const Waker = core.Waker;
const Context = core.Context;

/// A future that completes after a specified delay
pub const DelayFuture = struct {
    const Self = @This();

    deadline: i128,
    timer_id: ?u64,
    timer: *Timer,

    /// Create a new DelayFuture that will complete after the specified duration
    pub fn create(timer: *Timer, duration_ns: i128) Self {
        const now = std.time.nanoTimestamp();
        return Self{
            .deadline = now + duration_ns,
            .timer_id = null,
            .timer = timer,
        };
    }

    /// Create a DelayFuture from milliseconds
    pub fn from_millis(timer: *Timer, millis: u64) Self {
        return create(timer, @intCast(millis * std.time.ns_per_ms));
    }

    /// Create a DelayFuture from seconds
    pub fn from_secs(timer: *Timer, secs: u64) Self {
        return create(timer, @intCast(secs * std.time.ns_per_s));
    }

    /// Poll method for delay future
    pub fn poll(self: *Self, ctx: Context) Poll(void) {
        const now = std.time.nanoTimestamp();

        // Check if we've already completed
        if (now >= self.deadline) {
            // Clean up timer registration if it exists
            if (self.timer_id) |id| {
                self.timer.remove(id);
                self.timer_id = null;
            }
            return Poll(void){ .Ready = {} };
        }

        // Register with timer if we haven't already
        if (self.timer_id == null) {
            self.timer_id = self.timer.register(self.deadline, ctx.waker) catch |err| {
                // If we can't register with the timer, treat as ready to avoid hanging
                std.log.warn("Failed to register delay with timer: {}\n", .{err});
                return Poll(void){ .Ready = {} };
            };
        }

        return Poll(void){ .Pending = {} };
    }

    /// Convert to a generic Future
    pub fn as_future(self: *Self) Future(void) {
        const vtable = &VTable{
            .poll = pollImpl,
            .deinit = deinitImpl,
        };

        return Future(void){
            .vtable = vtable,
            .ptr = self,
        };
    }

    const VTable = Future(void).VTable;

    fn pollImpl(ptr: *anyopaque, ctx: Context) Poll(void) {
        const self: *DelayFuture = @ptrCast(@alignCast(ptr));
        return self.poll(ctx);
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *DelayFuture = @ptrCast(@alignCast(ptr));
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

/// Convenience function to create a delay future from milliseconds
pub fn delay_millis(timer: *Timer, millis: u64) DelayFuture {
    return DelayFuture.from_millis(timer, millis);
}

/// Convenience function to create a delay future from seconds
pub fn delay_secs(timer: *Timer, secs: u64) DelayFuture {
    return DelayFuture.from_secs(timer, secs);
}

test "DelayFuture immediate completion" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    // Create a delay that's already expired
    var delay = DelayFuture.create(&timer, -1000000); // 1ms in the past
    defer delay.deinit();

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

    // Should complete immediately
    const result = delay.poll(ctx);
    switch (result) {
        .Ready => {}, // Success
        .Pending => try std.testing.expect(false),
    }
}

test "DelayFuture pending and registration" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    // Create a delay that won't complete for a while
    var delay = DelayFuture.create(&timer, 10 * std.time.ns_per_s); // 10 seconds
    defer delay.deinit();

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

    const ctx = Context{ .waker = waker }; // Should be pending
    const result = delay.poll(ctx);
    switch (result) {
        .Ready => try std.testing.expect(false),
        .Pending => {}, // Success
    }

    // Should have registered with timer
    try std.testing.expect(delay.timer_id != null);
    try std.testing.expect(timer.count() == 1);

    // Polling again should not create another registration
    const result2 = delay.poll(ctx);
    switch (result2) {
        .Ready => try std.testing.expect(false),
        .Pending => {}, // Success
    }
    try std.testing.expect(timer.count() == 1);
}

test "DelayFuture from_millis" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    const before = std.time.nanoTimestamp();
    const delay = DelayFuture.from_millis(&timer, 100);
    const after = std.time.nanoTimestamp();

    // Deadline should be approximately 100ms from now
    const expected_min = before + 100 * std.time.ns_per_ms;
    const expected_max = after + 100 * std.time.ns_per_ms;

    try std.testing.expect(delay.deadline >= expected_min);
    try std.testing.expect(delay.deadline <= expected_max);
}

test "DelayFuture from_secs" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    const before = std.time.nanoTimestamp();
    const delay = DelayFuture.from_secs(&timer, 5);
    const after = std.time.nanoTimestamp();

    // Deadline should be approximately 5 seconds from now
    const expected_min = before + 5 * std.time.ns_per_s;
    const expected_max = after + 5 * std.time.ns_per_s;

    try std.testing.expect(delay.deadline >= expected_min);
    try std.testing.expect(delay.deadline <= expected_max);
}

test "DelayFuture as_future" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    var delay = DelayFuture.create(&timer, -1000000); // Already expired
    defer delay.deinit();

    var future = delay.as_future();

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

    // Should complete immediately
    const result = future.poll(ctx);
    switch (result) {
        .Ready => {}, // Success
        .Pending => try std.testing.expect(false),
    }
}

test "DelayFuture convenience functions" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    const delay1 = delay_millis(&timer, 100);
    const delay2 = delay_secs(&timer, 2);

    // Both should be valid DelayFuture instances
    try std.testing.expect(delay1.timer == &timer);
    try std.testing.expect(delay2.timer == &timer);

    // delay2 should have a later deadline than delay1
    try std.testing.expect(delay2.deadline > delay1.deadline);
}
