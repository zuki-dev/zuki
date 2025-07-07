const std = @import("std");

// Core modules
pub const core = @import("core/mod.zig");

pub const Task = core.Task;
pub const Future = core.Future;
pub const Poll = core.Poll;
pub const PollState = core.PollState;
pub const Waker = core.Waker;
pub const Context = core.Context;
pub const ready = core.ready;

test {
    std.testing.refAllDeclsRecursive(@This());
}
