//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

// Export the logger module
pub const logger = @import("logger.zig");

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}

test "logger memory leak demonstration" {
    // This test demonstrates the memory leak in the logger
    var logger_instance = logger.Logger.init(std.testing.allocator, logger.LogLevel.debug);
    defer logger_instance.deinit(); // Fix: properly cleanup the logger
    
    // Log some messages - this will allocate memory
    try logger_instance.info("Starting application: {s}", .{"zuki runtime"});
    try logger_instance.debug("Debug info: {d} connections", .{42});
    try logger_instance.warn("Warning: {s} is deprecated", .{"old_function"});
    try logger_instance.err("Error: {s} failed with code {d}", .{ "operation", 404 });
    
    // Verify that messages were logged
    try testing.expectEqual(@as(usize, 4), logger_instance.getLogCount());
    
    // The defer statement above will automatically call deinit() 
    // when this test function exits, preventing the memory leak
}

test "logger proper usage with manual cleanup" {
    // Test showing proper manual cleanup
    var logger_instance = logger.Logger.init(std.testing.allocator, logger.LogLevel.info);
    
    try logger_instance.info("Test message: {s}", .{"manual cleanup"});
    try testing.expectEqual(@as(usize, 1), logger_instance.getLogCount());
    
    // Manual cleanup - this prevents memory leak
    logger_instance.deinit();
}
