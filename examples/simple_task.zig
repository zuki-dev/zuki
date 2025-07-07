const std = @import("std");
const zuki = @import("zuki");
const Task = zuki.Task;
const Context = zuki.Context;
const Poll = zuki.Poll;
const SingleThreadedExecutor = zuki.SingleThreadedExecutor;
const ready = zuki.ready;

// A simple future that is already completed
pub const ImmediateFuture = struct {
    const Self = @This();

    result: u32,

    pub fn init(result: u32) Self {
        return Self{
            .result = result,
        };
    }

    pub fn poll(self: *Self, _: Context) Poll(u32) {
        return Poll(u32){ .Ready = self.result };
    }
};

// Convert any future to a task
fn taskFromFuture(future_ptr: anytype) Task {
    const FutureType = @TypeOf(future_ptr);

    const PollFn = struct {
        fn poll_impl(ptr: *anyopaque, ctx: *Context) Poll(void) {
            const typed_ptr: FutureType = @ptrCast(@alignCast(ptr));
            const result = typed_ptr.poll(ctx.*);

            switch (result) {
                .Ready => |value| {
                    std.debug.print("Task completed with value: {}\n", .{value});
                    return Poll(void){ .Ready = {} };
                },
                .Pending => {
                    return Poll(void){ .Pending = {} };
                },
            }
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

    std.debug.print("Starting simple task example\n", .{});

    // Create a future that completes immediately
    var immediate = ImmediateFuture.init(42);

    // Spawn a task from the future
    _ = try executor.spawn(taskFromFuture(&immediate));

    // Run the executor
    try executor.run();

    std.debug.print("Simple task example completed\n", .{});
}
