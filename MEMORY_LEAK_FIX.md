# Memory Leak Fix in zuki Logger

## Issue Description
The zuki logging implementation had a memory leak where log messages were allocated but never freed.

## Root Cause
1. **Log messages** were allocated using `std.fmt.allocPrint()` 
2. **ArrayList storage** was used to store messages
3. **No cleanup** - neither individual messages nor the ArrayList were freed

## Solution Implemented

### Before (Memory Leak):
```zig
pub const Logger = struct {
    allocator: Allocator,
    log_entries: std.ArrayList([]u8),
    
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .log_entries = std.ArrayList([]u8).init(allocator),
        };
    }
    
    // BUG: No deinit function!
    
    pub fn log(self: *Self, msg: []const u8) !void {
        const allocated_msg = try std.fmt.allocPrint(self.allocator, "{s}", .{msg});
        try self.log_entries.append(allocated_msg); // Memory leaked here!
    }
};
```

### After (Fixed):
```zig
pub const Logger = struct {
    allocator: Allocator,
    log_entries: std.ArrayList([]u8),
    
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .log_entries = std.ArrayList([]u8).init(allocator),
        };
    }
    
    // FIX: Proper cleanup function
    pub fn deinit(self: *Self) void {
        // Free all stored log messages
        for (self.log_entries.items) |message| {
            self.allocator.free(message);
        }
        // Free the ArrayList itself
        self.log_entries.deinit();
    }
    
    pub fn log(self: *Self, msg: []const u8) !void {
        const allocated_msg = try std.fmt.allocPrint(self.allocator, "{s}", .{msg});
        try self.log_entries.append(allocated_msg); // Now properly cleaned up
    }
};
```

## Usage Patterns

### Recommended (Automatic Cleanup):
```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    var logger = Logger.init(gpa.allocator());
    defer logger.deinit(); // Automatic cleanup on scope exit
    
    try logger.info("Application started");
    // ... use logger ...
    // Cleanup happens automatically
}
```

### Manual Cleanup:
```zig
pub fn someFunction() !void {
    var logger = Logger.init(allocator);
    
    try logger.info("Function started");
    // ... use logger ...
    
    logger.deinit(); // Manual cleanup
}
```

## Key Points
1. **Always call `deinit()`** on logger instances
2. **Use `defer`** for automatic cleanup
3. **Every allocation needs deallocation** in Zig
4. **Follow RAII patterns** for resource management

This fix ensures zero memory leaks when using the logger properly.