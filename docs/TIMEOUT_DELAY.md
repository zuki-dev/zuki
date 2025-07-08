# Zuki Timeout and Delay System

The Zuki async runtime provides comprehensive timeout and delay functionality through the `time` module. This system allows you to create futures that complete after a specified duration or wrap existing futures with timeout behavior.

## Core Components

### Timer

The `Timer` is the central coordinator for all time-based operations. It tracks deadlines and wakes tasks when their timeouts expire.

```zig
const Timer = zuki.Timer;

var timer = Timer.init(allocator);
defer timer.deinit();
```

### DelayFuture

A `DelayFuture` is a future that completes after a specified duration. It's perfect for implementing delays, pauses, or rate limiting in async code.

```zig
const DelayFuture = zuki.DelayFuture;

// Create delays using different time units
var delay_ms = DelayFuture.from_millis(&timer, 100);  // 100 milliseconds
var delay_sec = DelayFuture.from_secs(&timer, 2);     // 2 seconds
var delay_ns = DelayFuture.create(&timer, 1000000);   // 1 million nanoseconds

defer delay_ms.deinit();
defer delay_sec.deinit();  
defer delay_ns.deinit();
```

### TimeoutFuture

A `TimeoutFuture` wraps another future with a timeout. If the inner future doesn't complete within the specified time, the timeout future will complete with a `TimeoutError.Timeout`.

```zig
const TimeoutFuture = zuki.TimeoutFuture;
const TimeoutError = zuki.TimeoutError;

// Wrap any future with a timeout
var timeout_future = TimeoutFuture(i32).from_millis(&timer, some_future, 5000); // 5 second timeout
defer timeout_future.deinit();

// Poll the timeout future
const result = timeout_future.poll(ctx);
switch (result) {
    .Ready => |val| {
        if (val) |value| {
            // Inner future completed successfully
            std.log.info("Got value: {}", .{value});
        } else |err| {
            // Timeout occurred
            if (err == TimeoutError.Timeout) {
                std.log.warn("Operation timed out!");
            }
        }
    },
    .Pending => {
        // Still waiting
    },
}
```

## Integration with Executor

The timeout and delay system integrates seamlessly with the Zuki executor. You need to process expired timers in your event loop:

```zig
var timer = Timer.init(allocator);
defer timer.deinit();

var executor = SingleThreadedExecutor.init(allocator);
defer executor.deinit();

// Create and spawn delay tasks
var delay = DelayFuture.from_millis(&timer, 100);
defer delay.deinit();

const task = Task.from_future(&delay, 1);
try executor.spawn(task);

// Event loop with timer processing
while (executor.has_ready_tasks() or timer.count() > 0) {
    // Process expired timers first - this wakes up completed delays/timeouts
    try timer.process_expired();
    
    // Run one step of the executor
    try executor.step();
    
    // Optional: sleep to avoid busy waiting
    std.time.sleep(1 * std.time.ns_per_ms);
}
```

## Convenience Functions

The time module provides convenient functions for common patterns:

```zig
const time = zuki.time;

// Create delays easily
const short_delay = time.delay_millis(&timer, 50);
const long_delay = time.delay_secs(&timer, 10);

// Create timeouts with type inference
const quick_timeout = time.timeout_millis(i32, &timer, some_future, 1000);
const slow_timeout = time.timeout_secs(void, &timer, another_future, 30);
```

## Error Handling

Timeout operations can fail in the following ways:

- `TimeoutError.Timeout`: The operation timed out before completing
- Memory allocation errors when registering with the timer
- Any errors from the underlying future being wrapped

```zig
const result = timeout_future.poll(ctx);
switch (result) {
    .Ready => |val| {
        if (val) |success_value| {
            // Handle successful completion
        } else |err| switch (err) {
            TimeoutError.Timeout => {
                // Handle timeout
            },
            // Handle other potential errors from the inner future
        }
    },
    .Pending => {
        // Still waiting
    },
}
```

## Best Practices

1. **Always call `timer.process_expired()`** in your event loop before stepping the executor
2. **Clean up futures properly** using `defer future.deinit()` 
3. **Use appropriate time units** - milliseconds for short operations, seconds for longer ones
4. **Handle timeout errors explicitly** rather than treating them as generic failures
5. **Consider timer capacity** - each active delay/timeout registers with the timer

## Examples

See `examples/timeout_delay_example.zig` for comprehensive examples showing:
- Basic delay usage
- Timeout wrapping of slow operations  
- Multiple concurrent delays
- Integration with the executor

## Testing

The timeout and delay system includes comprehensive tests:
- Unit tests for Timer, DelayFuture, and TimeoutFuture
- Integration tests with the executor
- Concurrent operation tests
- Memory leak detection

Run tests with:
```bash
zig build test
```
