const std = @import("std");

// Core modules
pub const core = @import("core/mod.zig");
pub const runtime = @import("runtime/mod.zig");

// Re-export core types
pub const Task = core.Task;
pub const Future = core.Future;
pub const Poll = core.Poll;
pub const PollState = core.PollState;
pub const Waker = core.Waker;
pub const Context = core.Context;
pub const TaskHandle = core.TaskHandle;
pub const TaskState = core.TaskState;
pub const TaskPriority = core.TaskPriority;
pub const ready = core.ready;

// Re-export runtime types
pub const SingleThreadedExecutor = runtime.singleThreadedExecutor.SingleThreadedExecutor;

test {
    std.testing.refAllDeclsRecursive(@This());
}
