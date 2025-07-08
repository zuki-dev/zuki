const std = @import("std");
const core = @import("../core/mod.zig");

const Poll = core.Poll;
const PollState = core.PollState;
const Future = core.Future;
const Waker = core.Waker;
const Context = core.Context;

/// A timer system for tracking timeouts and delays
pub const Timer = struct {
    const Self = @This();

    /// A timer entry representing a scheduled timeout
    pub const Entry = struct {
        deadline: i128, // nanoseconds since epoch
        waker: Waker,
        id: u64,
    };

    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .entries = std.ArrayList(Entry).init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
    }

    /// Register a timeout with the timer
    pub fn register(self: *Self, deadline: i128, waker: Waker) !u64 {
        const id = self.next_id;
        self.next_id += 1;

        try self.entries.append(Entry{
            .deadline = deadline,
            .waker = waker,
            .id = id,
        });

        return id;
    }

    /// Remove a timer entry by ID
    pub fn remove(self: *Self, id: u64) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].id == id) {
                _ = self.entries.swapRemove(i);
                return;
            }
            i += 1;
        }
    }

    /// Process expired timers and wake them
    pub fn process_expired(self: *Self) !void {
        const now = std.time.nanoTimestamp();

        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (entry.deadline <= now) {
                // Wake the task
                entry.waker.wake();

                // Remove the expired entry
                _ = self.entries.swapRemove(i);
                // Don't increment i since we swapped an element into this position
            } else {
                i += 1;
            }
        }
    }

    /// Get the next deadline, or null if no timers are registered
    pub fn next_deadline(self: *const Self) ?i128 {
        if (self.entries.items.len == 0) return null;

        var earliest = self.entries.items[0].deadline;
        for (self.entries.items[1..]) |entry| {
            if (entry.deadline < earliest) {
                earliest = entry.deadline;
            }
        }

        return earliest;
    }

    /// Check if there are any expired timers
    pub fn has_expired(self: *const Self) bool {
        const now = std.time.nanoTimestamp();
        for (self.entries.items) |entry| {
            if (entry.deadline <= now) return true;
        }
        return false;
    }

    /// Get the number of registered timers
    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }
};

test "Timer basic functionality" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    // Timer should start empty
    try std.testing.expect(timer.count() == 0);
    try std.testing.expect(timer.next_deadline() == null);
    try std.testing.expect(!timer.has_expired());
}

test "Timer register and remove" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    const now = std.time.nanoTimestamp();
    const deadline = now + 1000000; // 1ms in the future

    // Create a dummy waker
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

    // Register a timer
    const id = try timer.register(deadline, waker);
    try std.testing.expect(timer.count() == 1);
    try std.testing.expect(timer.next_deadline().? == deadline);

    // Remove the timer
    timer.remove(id);
    try std.testing.expect(timer.count() == 0);
    try std.testing.expect(timer.next_deadline() == null);
}

test "Timer process expired" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    const now = std.time.nanoTimestamp();

    // Create a dummy waker that tracks if it was woken
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

    // Register a timer that's already expired
    const past_deadline = now - 1000000; // 1ms in the past
    _ = try timer.register(past_deadline, waker);

    try std.testing.expect(timer.has_expired());
    try std.testing.expect(!dummy_data.woken);

    // Process expired timers
    try timer.process_expired();

    try std.testing.expect(dummy_data.woken);
    try std.testing.expect(timer.count() == 0);
    try std.testing.expect(!timer.has_expired());
}

test "Timer multiple entries" {
    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    const now = std.time.nanoTimestamp();

    // Create dummy wakers
    const DummyData = struct {
        woken: bool = false,

        fn wake_fn(data: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.woken = true;
        }
    };

    var data1 = DummyData{};
    var data2 = DummyData{};
    var data3 = DummyData{};

    const waker1 = Waker{ .wake_fn = DummyData.wake_fn, .data = &data1 };
    const waker2 = Waker{ .wake_fn = DummyData.wake_fn, .data = &data2 };
    const waker3 = Waker{ .wake_fn = DummyData.wake_fn, .data = &data3 };

    // Register timers with different deadlines
    _ = try timer.register(now - 1000000, waker1); // expired
    _ = try timer.register(now + 1000000, waker2); // future
    _ = try timer.register(now - 500000, waker3); // expired

    try std.testing.expect(timer.count() == 3);
    try std.testing.expect(timer.has_expired());

    // Process expired timers
    try timer.process_expired();

    // Only the expired ones should be woken
    try std.testing.expect(data1.woken);
    try std.testing.expect(!data2.woken);
    try std.testing.expect(data3.woken);

    try std.testing.expect(timer.count() == 1); // Only the future timer remains
}
