//! Logger implementation for zuki runtime
//! This module provides logging functionality with configurable log levels
//!
//! MEMORY LEAK FIX:
//! The original issue was that log messages were allocated using allocPrint
//! but never freed, causing a memory leak. This has been fixed by:
//! 1. Adding a proper deinit() function that frees all allocated messages
//! 2. Ensuring the ArrayList itself is also properly deinitialized
//! 3. Following Zig's RAII pattern with defer statements in usage code

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

pub const Logger = struct {
    allocator: Allocator,
    level: LogLevel,
    // This ArrayList will cause a memory leak if not properly cleaned up
    log_entries: std.ArrayList([]u8),

    const Self = @This();

    pub fn init(allocator: Allocator, level: LogLevel) Self {
        return Self{
            .allocator = allocator,
            .level = level,
            .log_entries = std.ArrayList([]u8).init(allocator),
        };
    }

    // BUG: Missing deinit function - this causes the memory leak!
    // The log_entries ArrayList and all stored strings are never freed

    pub fn deinit(self: *Self) void {
        // Free all stored log messages
        for (self.log_entries.items) |message| {
            self.allocator.free(message);
        }
        // Free the ArrayList itself
        self.log_entries.deinit();
    }

    pub fn log(self: *Self, level: LogLevel, comptime fmt: []const u8, args: anytype) !void {
        if (@intFromEnum(level) < @intFromEnum(self.level)) {
            return; // Don't log if below current level
        }

        // Allocate memory for the log message - this creates the leak!
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        
        // Store the message in our internal buffer
        try self.log_entries.append(message);
        
        // Print to stderr
        std.debug.print("[{s}] {s}\n", .{ level.toString(), message });
    }

    pub fn debug(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.debug, fmt, args);
    }

    pub fn info(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.info, fmt, args);
    }

    pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.warn, fmt, args);
    }

    pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.err, fmt, args);
    }

    pub fn getLogCount(self: *const Self) usize {
        return self.log_entries.items.len;
    }
};