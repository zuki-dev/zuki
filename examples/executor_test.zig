const std = @import("std");
const zuki = @import("../root.zig");
const Task = zuki.Task;
const Context = zuki.Context;
const Poll = zuki.Poll;
const SingleThreadedExecutor = zuki.SingleThreadedExecutor;

// A simple future that completes after a certain number of polls
pub const DelayFuture = struct {
    const Self = @This();

    remaining: usize,
    result: u32,

    pub fn init(delay: usize, result: u32) Self {
        return Self{
            .remaining = delay,
            .result = result,
        };
    }

    pub fn poll(self: *Self, ctx: Context) Poll(u32) {
        if (self.remaining == 0) {
            return Poll(u32){ .Ready = self.result };
        } else {
            self.remaining -= 1;
            // Wake up on next tick
            ctx.waker.wake();
            return Poll(u32){ .Pending = {} };
        }
    }
};

// Convert any future to a task
fn taskFromFuture(future_ptr: anytype) Task {
    const FutureType = @TypeOf(future_ptr);

    const PollFn = struct {
        fn poll_impl(ptr: *anyopaque, ctx: *Context) Poll(void) {
            const typed_ptr: FutureType = @ptrCast(ptr);
            _ = typed_ptr.poll(ctx.*);
            return Poll(void){ .Pending = {} };
        }
    };

    return Task{
        .id = 0, // Will be set by executor
        .state = .Ready,
        .priority = .Normal,
        .future_ptr = future_ptr,
        .poll_fn = PollFn.poll_impl,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create the executor
    var executor = try SingleThreadedExecutor.init(allocator);
    defer executor.deinit();

    std.debug.print("Starting executor test\n", .{});

    // Create futures that complete after different delays
    var delay1 = DelayFuture.init(0, 100); // Completes immediately
    var delay2 = DelayFuture.init(1, 200); // Completes after 1 poll
    var delay3 = DelayFuture.init(2, 300); // Completes after 2 polls

    // Spawn tasks from futures
    _ = try executor.spawn(taskFromFuture(&delay1));
    _ = try executor.spawn(taskFromFuture(&delay2));
    _ = try executor.spawn(taskFromFuture(&delay3));

    // Run the executor for a few steps
    std.debug.print("Running step 1\n", .{});
    _ = try executor.step();
    std.debug.print("Running step 2\n", .{});
    _ = try executor.step();
    std.debug.print("Running step 3\n", .{});
    _ = try executor.step();

    // Run until completion
    std.debug.print("Running to completion\n", .{});
    try executor.run();

    std.debug.print("Executor test completed\n", .{});
}
