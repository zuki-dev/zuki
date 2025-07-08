const std = @import("std");

pub const DelayFuture = @import("delay.zig").DelayFuture;
pub const TimeoutFuture = @import("timeout.zig").TimeoutFuture;
pub const TimeoutError = @import("timeout.zig").TimeoutError;
pub const Timer = @import("timer.zig").Timer;

// Convenience functions
pub const delay = DelayFuture.create;
// Note: timeout requires a type parameter, so we export the timeout functions directly
pub const timeout_millis = @import("timeout.zig").timeout_millis;
pub const timeout_secs = @import("timeout.zig").timeout_secs;

test {
    std.testing.refAllDeclsRecursive(@This());
}
