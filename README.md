# zuki
High-performance async runtime for Zig — fast, cross-platform, and zero-cost by design

## Features

- Task-based asynchronous execution
- Future/Poll pattern similar to Rust's async model
- Waker-based task notification system
- Priority-based task scheduling
- Single-threaded executor (multi-threaded coming soon)

## Waker System

The Zuki waker system is designed to efficiently manage asynchronous task execution. When a task is polled and returns `Pending`, it's moved to a pending queue. The waker mechanism allows the task to signal when it's ready to make progress again.

Key components:

1. **Waker**: A struct that contains a function pointer and data pointer for waking tasks
2. **Context**: Passed to futures during polling, contains the waker
3. **WakerData**: Links tasks to their executor for re-scheduling

When a future signals it's ready (e.g., I/O completes, timer expires), it calls `waker.wake()`, which moves the task from the pending queue back to the ready queue.

## Running the Examples

### Executor Test

To run the single-threaded executor test:

```bash
zig build executor-test
```

This example demonstrates:
- Creating futures with different completion delays
- Spawning tasks from these futures
- The waker mechanism moving tasks between queues
- Running the executor to completion
