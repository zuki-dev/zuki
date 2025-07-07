const std = @import("std");

/// Represents the state of a task in the Zuki runtime.
/// This is a union type that can either be `Ready` with a value of type `
/// T`, or `Pending` with no value.
pub fn Poll(comptime T: type) type {
    return union(enum) {
        Ready: T,
        Pending: void,
    };
}

/// Context passed to futures during polling
pub const Context = struct {
    waker: Waker,

    /// Get the waker for this context
    pub fn get_waker(self: *const Context) Waker {
        return self.waker;
    }
};

/// Mechanism for waking up a task when it can make progress
pub const Waker = struct {
    // Function pointer for the wake implementation
    wake_fn: *const fn (data: *anyopaque) void,
    // Data pointer passed to wake_fn
    data: *anyopaque,

    /// Wake up the associated task
    pub fn wake(self: *Waker) void {
        self.wake_fn(self.data);
    }

    /// Create a new waker
    pub fn init(wake_fn: *const fn (data: *anyopaque) void, data: *anyopaque) Waker {
        return Waker{
            .wake_fn = wake_fn,
            .data = data,
        };
    }
};

/// Represents the state of a poll in the Zuki runtime.
/// This struct wraps the `Poll` type and provides methods to check the state.
pub const PollState = struct {
    /// The current state of the poll.
    state: Poll(bool),

    /// Returns true if the poll is ready.
    pub fn isReady(self: PollState) bool {
        return switch (self.state) {
            .Ready => |value| value,
            .Pending => false,
        };
    }

    /// Returns true if the poll is pending.
    pub fn isPending(self: PollState) bool {
        return switch (self.state) {
            .Pending => true,
            .Ready => false,
        };
    }
};

/// Represents the state of a task in the Zuki runtime.
pub const TaskState = enum(u8) {
    Ready,
    Pending,
    Running,
    Completed,
    Failed,
};

// Task priority levels.
pub const TaskPriority = enum(u8) {
    Low = 0,
    Normal = 1,
    High = 2,
    Critical = 3,
};

// Handle to a spawned task.
pub const TaskHandle = struct {
    id: u64,

    // TODO: Add methods or task control
    // pub fn cancel(self: TaskHandle) void {}
    // pub fn resume(self: TaskHandle) void {}
    // pub fn suspend(self: TaskHandle) void {}
};

/// Generic future interface
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        // Virtual function table for polymorphic futures
        vtable: *const VTable,
        // Pointer to the actual future data
        ptr: *anyopaque,

        const VTable = struct {
            poll: *const fn (ptr: *anyopaque, ctx: Context) Poll(T),
            deinit: *const fn (ptr: *anyopaque) void,
        };

        /// Poll this future for completion
        pub fn poll(self: *Self, ctx: Context) Poll(T) {
            return self.vtable.poll(self.ptr, ctx);
        }

        /// Clean up this future
        pub fn deinit(self: *Self) void {
            self.vtable.deinit(self.ptr);
        }
    };
}

pub const Task = struct {
    const Self = @This();

    id: u64,
    state: TaskState,
    priority: TaskPriority,
    // Type-erased future - we'll store the actual future here
    future_ptr: *anyopaque,
    poll_fn: *const fn (ptr: *anyopaque, ctx: *Context) Poll(void),

    pub fn init(future_ptr: *anyopaque, poll_fn: *const fn (ptr: *anyopaque, ctx: *Context) Poll(void), id: u64) Self {
        return Self{
            .id = id,
            .state = .Ready,
            .priority = .Normal,
            .future_ptr = future_ptr,
            .poll_fn = poll_fn,
        };
    }

    /// Poll this task
    pub fn poll(self: *Self, ctx: Context) Poll(void) {
        return self.poll_fn(self.future_ptr, @constCast(&ctx));
    }

    /// Helper to create a task from any future that returns void
    pub fn from_future(future_ptr: anytype, id: u64) Self {
        const PollFn = struct {
            fn poll_impl(ptr: *anyopaque, ctx: *Context) Poll(void) {
                const typed_ptr = @as(@TypeOf(future_ptr), @ptrCast(ptr));
                const result = typed_ptr.poll(ctx.*);
                return switch (result) {
                    .Ready => Poll(void){ .Ready = {} },
                    .Pending => Poll(void){ .Pending = {} },
                };
            }
        };

        return Self.init(future_ptr, PollFn.poll_impl, id);
    }
};

/// A future that is immediately ready
pub fn ReadyFuture(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T,

        pub fn poll(self: *Self, ctx: Context) Poll(T) {
            _ = ctx; // Context not needed for ready futures
            return Poll(T){ .Ready = self.value };
        }

        pub fn future(self: *Self) Future(T) {
            const vtable = &VTable{
                .poll = pollImpl,
                .deinit = deinitImpl,
            };

            return Future(T){
                .vtable = vtable,
                .ptr = self,
            };
        }

        const VTable = Future(T).VTable;

        fn pollImpl(ptr: *anyopaque, ctx: Context) Poll(T) {
            const self = @as(*Self, @ptrCast(ptr));
            return self.poll(ctx);
        }

        fn deinitImpl(ptr: *anyopaque) void {
            _ = ptr; // ReadyFuture doesn't need cleanup
        }
    };
}

test "PollState enum" {
    const poll_ready = PollState{ .state = Poll(bool){ .Ready = true } };
    const poll_pending = PollState{ .state = Poll(bool){ .Pending = {} } };

    try std.testing.expect(poll_ready.isReady());
    try std.testing.expect(!poll_ready.isPending());
    try std.testing.expect(!poll_pending.isReady());
    try std.testing.expect(poll_pending.isPending());
}

test "Task creation" {
    // Test the from_future helper since that's what we actually use
    const TestFuture = struct {
        const Self = @This();

        pub fn poll(self: *Self, ctx: Context) Poll(void) {
            _ = self;
            _ = ctx;
            return Poll(void){ .Ready = {} };
        }
    };

    var test_future = TestFuture{};
    const test_task = Task.from_future(&test_future, 1);

    try std.testing.expect(test_task.id == 1);
    try std.testing.expect(test_task.state == .Ready);
    try std.testing.expect(test_task.priority == .Normal);
}

pub fn ready(comptime T: type, value: T) ReadyFuture(T) {
    return ReadyFuture(T){ .value = value };
}

test "ReadyFuture" {
    var ready_future = ready(i32, 42);
    var dummy_data: u8 = 0;
    const waker = Waker.init(dummyWake, &dummy_data);
    const ctx = Context{ .waker = waker };

    const result = ready_future.poll(ctx);
    switch (result) {
        .Ready => |value| try std.testing.expect(value == 42),
        .Pending => try std.testing.expect(false),
    }
}

fn dummyWake(data: *anyopaque) void {
    _ = data;
    // Do nothing - this is just for testing
}
