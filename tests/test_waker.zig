const std = @import("std");
const testing = std.testing;
const zuki = @import("zuki");
const Waker = zuki.Waker;
const Context = zuki.Context;

// Test data for waker callbacks
var global_wake_count: u32 = 0;
var global_wake_data: ?*anyopaque = null;

fn incrementWakeCount(data: *anyopaque) void {
    global_wake_count += 1;
    global_wake_data = data;
}

fn customWakeFunction(data: *anyopaque) void {
    const counter = @as(*u32, @ptrCast(@alignCast(data)));
    counter.* += 10;
}

test "Waker - basic creation and wake" {
    // Reset global state
    global_wake_count = 0;
    global_wake_data = null;

    var test_data: u8 = 42;
    const waker = Waker.init(incrementWakeCount, &test_data);

    // Verify initial state
    try testing.expect(global_wake_count == 0);
    try testing.expect(global_wake_data == null);

    // Wake the waker
    waker.wake();

    // Verify the wake function was called
    try testing.expect(global_wake_count == 1);
    try testing.expect(global_wake_data == @as(*anyopaque, @ptrCast(&test_data)));
}

test "Waker - multiple wakes" {
    global_wake_count = 0;

    var test_data: u8 = 0;
    const waker = Waker.init(incrementWakeCount, &test_data);

    // Wake multiple times
    waker.wake();
    waker.wake();
    waker.wake();

    try testing.expect(global_wake_count == 3);
}

test "Waker - custom wake function" {
    var counter: u32 = 0;
    const waker = Waker.init(customWakeFunction, &counter);

    // Initial state
    try testing.expect(counter == 0);

    // Wake and verify custom behavior
    waker.wake();
    try testing.expect(counter == 10);

    // Wake again
    waker.wake();
    try testing.expect(counter == 20);
}

test "Waker - different data types" {
    // Test with different data types

    // String data test
    const StringTest = struct {
        var str_received: ?[]const u8 = null;

        fn wake(data: *anyopaque) void {
            const str_ptr = @as(*[]const u8, @ptrCast(@alignCast(data)));
            str_received = str_ptr.*;
        }
    };

    var str_data: []const u8 = "test_string";
    const str_waker = Waker.init(StringTest.wake, @ptrCast(&str_data));
    str_waker.wake();

    try testing.expectEqualStrings(StringTest.str_received.?, "test_string");

    // Struct data test
    const TestStruct = struct {
        id: u32,
        value: f32,
    };

    const StructTest = struct {
        var struct_received: ?TestStruct = null;

        fn wake(data: *anyopaque) void {
            const struct_ptr = @as(*TestStruct, @ptrCast(@alignCast(data)));
            struct_received = struct_ptr.*;
        }
    };

    var struct_data = TestStruct{ .id = 123, .value = 3.14 };
    const struct_waker = Waker.init(StructTest.wake, &struct_data);
    struct_waker.wake();

    try testing.expect(StructTest.struct_received.?.id == 123);
    try testing.expect(StructTest.struct_received.?.value == 3.14);
}

test "Context - basic functionality" {
    var test_data: u8 = 100;
    const waker = Waker.init(incrementWakeCount, &test_data);
    const context = Context{ .waker = waker };

    // Test getting the waker from context
    const retrieved_waker = context.get_waker();

    // Verify they have the same function and data pointers
    try testing.expect(retrieved_waker.wake_fn == waker.wake_fn);
    try testing.expect(retrieved_waker.data == waker.data);

    // Test that we can wake through the retrieved waker
    global_wake_count = 0;
    retrieved_waker.wake();
    try testing.expect(global_wake_count == 1);
}

test "Context - immutable access pattern" {
    var test_data: u32 = 0;
    const waker = Waker.init(customWakeFunction, &test_data);
    const context = Context{ .waker = waker };

    // Context should be passable as const
    const const_context: *const Context = &context;
    const waker_from_const = const_context.get_waker();

    // Should still be able to wake
    waker_from_const.wake();
    try testing.expect(test_data == 10);
}

test "Waker - function pointer stability" {
    // Test that function pointers work correctly across different calls
    var counter1: u32 = 0;
    var counter2: u32 = 0;

    const waker1 = Waker.init(customWakeFunction, &counter1);
    const waker2 = Waker.init(customWakeFunction, &counter2);

    // Both should use the same function but different data
    try testing.expect(waker1.wake_fn == waker2.wake_fn);
    try testing.expect(waker1.data != waker2.data);

    // Wake each and verify they affect different counters
    waker1.wake();
    try testing.expect(counter1 == 10);
    try testing.expect(counter2 == 0);

    waker2.wake();
    try testing.expect(counter1 == 10);
    try testing.expect(counter2 == 10);
}

test "Waker - memory safety" {
    // Test that we can safely work with wakers even after data changes
    const MemoryTest = struct {
        var received_value: i32 = 0;

        fn wake(data: *anyopaque) void {
            const int_ptr = @as(*i32, @ptrCast(@alignCast(data)));
            received_value = int_ptr.*;
        }
    };

    var test_value: i32 = 42;
    const waker = Waker.init(MemoryTest.wake, &test_value);

    // Change the value and wake
    test_value = 100;
    waker.wake();
    try testing.expect(MemoryTest.received_value == 100);

    // Change again and wake
    test_value = -50;
    waker.wake();
    try testing.expect(MemoryTest.received_value == -50);
}

test "Waker - concurrent-style usage simulation" {
    // Simulate how wakers might be used in async contexts
    const TaskTest = struct {
        var wake_called = false;

        fn wake(data: *anyopaque) void {
            const ready_ptr = @as(*bool, @ptrCast(@alignCast(data)));
            ready_ptr.* = true;
            wake_called = true;
        }
    };

    var task_ready = false;
    const waker = Waker.init(TaskTest.wake, &task_ready);

    // Initial state
    try testing.expect(!task_ready);
    try testing.expect(!TaskTest.wake_called);

    // Simulate external event triggering wake
    waker.wake();

    // Task should now be ready
    try testing.expect(task_ready);
    try testing.expect(TaskTest.wake_called);
}
