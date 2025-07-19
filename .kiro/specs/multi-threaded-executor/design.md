# Multi-Threaded Work-Stealing Executor Design

## Overview

This design adds a high-performance multi-threaded work-stealing executor (`WorkStealingExecutor`) to the Zuki async runtime. The executor leverages lock-free data structures, work-stealing algorithms, and efficient thread pool management while maintaining compatibility with existing Task, Future, and Waker abstractions.

The design preserves the existing `SingleThreadedExecutor` and follows Zuki's modular architecture by adding the new executor to the `runtime` module.

## Architecture

### High-Level Components

```
┌─────────────────────────────────────────────────────────────┐
│                    Zuki Runtime                             │
├─────────────────────────────────────────────────────────────┤
│  SingleThreadedExecutor  │  WorkStealingExecutor            │
│  (existing)              │  (new)                           │
│                          │                                  │
│                          │  ┌─────────────────────────────┐ │
│                          │  │     Thread Pool Manager     │ │
│                          │  └─────────────────────────────┘ │
│                          │  ┌─────────────────────────────┐ │
│                          │  │    Worker Thread Array      │ │
│                          │  └─────────────────────────────┘ │
│                          │  ┌─────────────────────────────┐ │
│                          │  │     Global Task Queue       │ │
│                          │  └─────────────────────────────┘ │
│                          │  ┌─────────────────────────────┐ │
│                          │  │   Work-Stealing Scheduler   │ │
│                          │  └─────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Core Components

1. **WorkStealingExecutor**: Main executor interface
2. **WorkerThread**: Individual worker thread with local task queue
3. **GlobalQueue**: Shared lock-free queue for task overflow and initial distribution
4. **LocalQueue**: Per-thread lock-free deque for work-stealing
5. **ThreadPool**: Manages worker thread lifecycle
6. **TaskBatch**: Efficient batch submission mechanism
7. **WakeManager**: Coordinates task waking across threads

## Components and Interfaces

### WorkStealingExecutor

```zig
pub const WorkStealingExecutor = struct {
    const Self = @This();
    
    // Configuration
    config: Config,
    
    // Thread management
    thread_pool: ThreadPool,
    
    // Task queues
    global_queue: GlobalQueue,
    
    // Synchronization
    shutdown_signal: std.atomic.Atomic(bool),
    
    // Resource management
    allocator: std.mem.Allocator,
    next_task_id: std.atomic.Atomic(u64),
    
    pub const Config = struct {
        num_threads: ?u32 = null, // Default to CPU count
        stack_size: u32 = 1024 * 1024, // 1MB default
        local_queue_capacity: u32 = 256,
        global_queue_capacity: u32 = 1024,
    };
    
    pub fn init(allocator: std.mem.Allocator, config: Config) !Self;
    pub fn deinit(self: *Self) void;
    pub fn spawn(self: *Self, task: Task) !TaskHandle;
    pub fn spawn_batch(self: *Self, batch: TaskBatch) ![]TaskHandle;
    pub fn run(self: *Self) !void;
    pub fn shutdown(self: *Self) void;
};
```

### WorkerThread

```zig
const WorkerThread = struct {
    const Self = @This();
    
    // Thread identity
    id: u32,
    handle: std.Thread,
    
    // Local task storage
    local_queue: LocalQueue,
    
    // References to shared state
    executor: *WorkStealingExecutor,
    global_queue: *GlobalQueue,
    other_workers: []WorkerThread,
    
    // Synchronization
    park_event: Event,
    
    // Statistics (for debugging/monitoring)
    tasks_executed: std.atomic.Atomic(u64),
    tasks_stolen: std.atomic.Atomic(u64),
    
    fn run(self: *Self) void;
    fn try_get_task(self: *Self) ?*Task;
    fn try_steal_from(self: *Self, victim: *WorkerThread) ?*Task;
    fn park(self: *Self) void;
    fn unpark(self: *Self) void;
};
```

### Lock-Free Data Structures

#### GlobalQueue (Multi-Producer, Multi-Consumer)

```zig
const GlobalQueue = struct {
    const Self = @This();
    
    // Lock-free stack for task nodes
    head: std.atomic.Atomic(?*TaskNode),
    
    // Consumer coordination
    consumer_lock: std.atomic.Atomic(bool),
    
    fn push(self: *Self, task: *Task) void;
    fn try_pop(self: *Self) ?*Task;
    fn push_batch(self: *Self, batch: TaskBatch) void;
};
```

#### LocalQueue (Single-Producer, Multi-Consumer Deque)

```zig
const LocalQueue = struct {
    const Self = @This();
    
    // Ring buffer for tasks
    buffer: []std.atomic.Atomic(?*Task),
    capacity: u32,
    
    // Indices for deque operations
    head: std.atomic.Atomic(u32), // For stealing (FIFO)
    tail: std.atomic.Atomic(u32), // For local access (LIFO)
    
    fn push(self: *Self, task: *Task) !void;
    fn pop(self: *Self) ?*Task; // Local LIFO pop
    fn steal(self: *Self) ?*Task; // Remote FIFO steal
    fn is_empty(self: *Self) bool;
    fn len(self: *Self) u32;
};
```

### TaskBatch

```zig
pub const TaskBatch = struct {
    const Self = @This();
    
    tasks: std.ArrayList(*Task),
    
    pub fn init(allocator: std.mem.Allocator) Self;
    pub fn deinit(self: *Self) void;
    pub fn add(self: *Self, task: Task) !void;
    pub fn len(self: *Self) usize;
    pub fn clear(self: *Self) void;
    
    // Internal iterator for efficient processing
    fn iterator(self: *Self) TaskIterator;
};
```

### Event (for thread parking/unparking)

```zig
const Event = struct {
    const Self = @This();
    
    state: std.atomic.Atomic(u32),
    
    const EMPTY = 0;
    const NOTIFIED = 1;
    const PARKED = 2;
    
    fn wait(self: *Self) void;
    fn notify(self: *Self) void;
    fn notify_all(self: *Self) void;
};
```

## Data Models

### Task Node (for queue linking)

```zig
const TaskNode = struct {
    task: *Task,
    next: std.atomic.Atomic(?*TaskNode),
};
```

### Thread-Safe Waker Data

```zig
const WorkStealingWakerData = struct {
    executor: *WorkStealingExecutor,
    task_id: u64,
    preferred_thread: ?u32, // Hint for thread affinity
};
```

## Error Handling

### Error Types

```zig
pub const ExecutorError = error{
    ThreadSpawnFailed,
    QueueFull,
    AlreadyShutdown,
    InvalidConfiguration,
    OutOfMemory,
};
```

### Error Handling Strategy

1. **Thread Spawn Failures**: Continue with fewer threads, log warning
2. **Queue Overflow**: Gracefully handle by blocking or returning error
3. **Memory Allocation**: Propagate OutOfMemory errors to caller
4. **Task Panics**: Isolate to individual tasks, don't crash executor
5. **Shutdown Races**: Use atomic flags to coordinate clean shutdown

## Testing Strategy

### Unit Tests

1. **Lock-Free Data Structures**
   - Single-threaded correctness
   - Memory ordering verification
   - ABA problem prevention

2. **Work-Stealing Algorithm**
   - Load balancing effectiveness
   - Starvation prevention
   - Fairness properties

3. **Thread Pool Management**
   - Proper startup/shutdown
   - Resource cleanup
   - Error handling

### Integration Tests

1. **Executor Compatibility**
   - Same Task/Future/Waker APIs work
   - Seamless switching between executors
   - Performance comparisons

2. **Concurrent Workloads**
   - CPU-intensive tasks
   - I/O-bound tasks
   - Mixed workloads

3. **Stress Tests**
   - High task submission rates
   - Many concurrent tasks
   - Resource exhaustion scenarios

### Performance Tests

1. **Throughput Benchmarks**
   - Tasks per second
   - Scaling with thread count
   - Comparison with single-threaded

2. **Latency Measurements**
   - Task scheduling latency
   - Wake-up latency
   - Work-stealing overhead

3. **Memory Usage**
   - Queue memory overhead
   - Thread stack usage
   - Allocation patterns

## Implementation Phases

### Phase 1: Core Infrastructure
- Lock-free data structures (GlobalQueue, LocalQueue)
- Event synchronization primitive
- Basic WorkerThread structure

### Phase 2: Work-Stealing Algorithm
- Task stealing logic
- Load balancing heuristics
- Thread parking/unparking

### Phase 3: Executor Integration
- WorkStealingExecutor implementation
- Waker integration for multi-threading
- TaskBatch submission

### Phase 4: Optimization & Polish
- Performance tuning
- Memory optimization
- Comprehensive testing

## Memory Management

### Allocation Strategy
- Use provided allocator for all dynamic allocations
- Pre-allocate worker thread structures
- Pool TaskNode objects to reduce allocation overhead
- Careful cleanup on shutdown to prevent leaks

### Memory Ordering
- Use `std.atomic.Ordering.Acquire` for consuming operations
- Use `std.atomic.Ordering.Release` for publishing operations
- Use `std.atomic.Ordering.AcqRel` for read-modify-write operations
- Use `std.atomic.Ordering.SeqCst` only when necessary for total ordering

## Performance Considerations

### Work-Stealing Optimizations
- Steal half of victim's tasks to amortize stealing cost
- Use randomized victim selection to avoid hot-spots
- Implement exponential backoff for failed steal attempts
- Prefer local queue access (LIFO) over stealing (FIFO)

### Cache Efficiency
- Align data structures to cache line boundaries
- Minimize false sharing between threads
- Use thread-local storage for frequently accessed data
- Batch operations to improve cache utilization

### Contention Reduction
- Use lock-free algorithms where possible
- Implement backoff strategies for high contention
- Separate read and write paths in data structures
- Use thread affinity hints for better locality