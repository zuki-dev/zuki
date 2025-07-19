const std = @import("std");
const testing = std.testing;
const zuki = @import("zuki");
const Poll = zuki.Poll;
const PollState = zuki.PollState;

test "Poll(T) - Ready state" {
    const ready_int = Poll(i32){ .Ready = 42 };
    const ready_bool = Poll(bool){ .Ready = true };
    const ready_void = Poll(void){ .Ready = {} };

    // Test integer poll
    switch (ready_int) {
        .Ready => |value| try testing.expect(value == 42),
        .Pending => try testing.expect(false),
    }

    // Test boolean poll
    switch (ready_bool) {
        .Ready => |value| try testing.expect(value == true),
        .Pending => try testing.expect(false),
    }

    // Test void poll
    switch (ready_void) {
        .Ready => {}, // Should reach here
        .Pending => try testing.expect(false),
    }
}

test "Poll(T) - Pending state" {
    const pending_int = Poll(i32){ .Pending = {} };
    const pending_bool = Poll(bool){ .Pending = {} };
    const pending_void = Poll(void){ .Pending = {} };

    // Test all pending variants
    switch (pending_int) {
        .Ready => try testing.expect(false),
        .Pending => {}, // Should reach here
    }

    switch (pending_bool) {
        .Ready => try testing.expect(false),
        .Pending => {}, // Should reach here
    }

    switch (pending_void) {
        .Ready => try testing.expect(false),
        .Pending => {}, // Should reach here
    }
}

test "Poll(T) - Complex types" {
    const TestStruct = struct {
        id: u32,
        name: []const u8,
    };

    const test_data = TestStruct{ .id = 123, .name = "test" };
    const ready_struct = Poll(TestStruct){ .Ready = test_data };
    const pending_struct = Poll(TestStruct){ .Pending = {} };

    switch (ready_struct) {
        .Ready => |value| {
            try testing.expect(value.id == 123);
            try testing.expectEqualStrings(value.name, "test");
        },
        .Pending => try testing.expect(false),
    }

    switch (pending_struct) {
        .Ready => try testing.expect(false),
        .Pending => {}, // Should reach here
    }
}

test "Poll(T) - Error types" {
    const ErrorType = error{TestError};
    const ready_ok = Poll(ErrorType!i32){ .Ready = 42 };
    const pending_error = Poll(ErrorType!i32){ .Pending = {} };
    const ready_with_error = Poll(ErrorType!i32){ .Ready = ErrorType.TestError };

    switch (ready_ok) {
        .Ready => |value| {
            const unwrapped = value catch unreachable;
            try testing.expect(unwrapped == 42);
        },
        .Pending => try testing.expect(false),
    }

    switch (pending_error) {
        .Ready => try testing.expect(false),
        .Pending => {}, // Should reach here
    }

    switch (ready_with_error) {
        .Ready => |value| try testing.expectError(ErrorType.TestError, value),
        .Pending => try testing.expect(false),
    }
}

test "PollState helper struct" {
    const ready_true = PollState{ .state = Poll(bool){ .Ready = true } };
    const ready_false = PollState{ .state = Poll(bool){ .Ready = false } };
    const pending = PollState{ .state = Poll(bool){ .Pending = {} } };

    // Test isReady method
    try testing.expect(ready_true.isReady() == true);
    try testing.expect(ready_false.isReady() == false);
    try testing.expect(pending.isReady() == false);

    // Test isPending method
    try testing.expect(ready_true.isPending() == false);
    try testing.expect(ready_false.isPending() == false);
    try testing.expect(pending.isPending() == true);
}

test "Poll state transitions" {
    // Simulate a future that goes from pending to ready
    var is_ready = false;

    var poll_result = if (is_ready) Poll(i32){ .Ready = 42 } else Poll(i32){ .Pending = {} };

    // First poll should be pending
    switch (poll_result) {
        .Ready => try testing.expect(false),
        .Pending => {}, // Expected
    }

    // Change state and poll again
    is_ready = true;
    poll_result = if (is_ready) Poll(i32){ .Ready = 42 } else Poll(i32){ .Pending = {} };

    // Second poll should be ready
    switch (poll_result) {
        .Ready => |value| try testing.expect(value == 42),
        .Pending => try testing.expect(false),
    }
}

test "Poll memory layout" {
    // Test that Poll doesn't add unnecessary overhead
    const poll_int = Poll(i32){ .Ready = 42 };
    const poll_void = Poll(void){ .Ready = {} };

    // These should be compact representations
    // Note: Union with tag needs extra space for discriminant
    try testing.expect(@sizeOf(Poll(i32)) <= @sizeOf(i32) + @sizeOf(u8) + 4); // tag + value + padding
    try testing.expect(@sizeOf(Poll(void)) <= 8); // just the tag with some padding

    _ = poll_int;
    _ = poll_void;
}
