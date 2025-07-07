# zuki
High-performance async runtime for Zig — fast, cross-platform, and zero-cost by design

## ⚠️ EARLY DEVELOPMENT NOTICE ⚠️

**This project is in early development and is not ready for production use!**

Zuki is currently being actively developed, and APIs may change frequently without warning. Use at your own risk.

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

## Roadmap to MVP (0.1.0)

The following features are planned for the initial 0.1.0 release:

**Foundation (Complete):**
- [x] Task abstraction with priority scheduling
- [x] Future/Poll pattern for asynchronous operations
- [x] Waker mechanism for task notifications
- [x] Single-threaded executor

**High-Level APIs:**
- [ ] Runtime abstraction for easier usage
- [ ] Built-in delay/timeout futures
- [ ] Simplified task spawning
- [ ] Basic I/O operations (file, network)

**Advanced Features:**
- [ ] Cancellation support
- [ ] Task joining and combining
- [ ] Error handling patterns
- [ ] Complete documentation and examples

**Future (Post-MVP):**
- [ ] `async/await` syntax (depends on Zig language features)
- [ ] Multi-threaded executor
- [ ] Work-stealing scheduler

## Running the Examples

All examples can be built with:

```bash
zig build ex
```

### Low-Level Executor Test

```bash
zig build executor_test
```

This is a **low-level example** that demonstrates the foundational APIs:
- Manual task creation and spawning
- Direct executor management
- Explicit polling and waker usage

### Clean Async Example (Future Vision)

```bash
zig build clean_async
```

This shows a **higher-level API** that's planned for future releases:
- Simplified runtime management
- Cleaner task spawning
- Built-in delay primitives

**Note**: The current examples are verbose because we're at the foundational layer. Higher-level APIs like `async/await` syntax and built-in I/O primitives will make usage much more ergonomic.
