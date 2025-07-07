const std = @import("std");
const Task = @import("../core/mod.zig").Task;
const Future = @import("../core/mod.zig").Future;
const Poll = @import("../core/mod.zig").Poll;
const PollState = @import("../core/mod.zig").PollState;
const Context = @import("../core/mod.zig").Context;
const Waker = @import("../core/mod.zig").Waker;
const TaskHandle = @import("../core/mod.zig").TaskHandle;
const TaskPriority = @import("../core/mod.zig").TaskPriority;
const TaskState = @import("../core/mod.zig").TaskState;

/// Single-threaded executor for running tasks
pub const SingleThreadedExecutor = struct {
    // Define the comparison function first so it can be referenced
    /// Task comparison function for priority queue (higher priority first)
    fn taskCompareFn(_: void, a: *Task, b: *Task) std.math.Order {
        // Higher priority comes first (reverse order)
        return std.math.order(@intFromEnum(b.priority), @intFromEnum(a.priority));
    }

    ready_tasks: std.PriorityQueue(*Task, void, taskCompareFn),
    pending_tasks: std.ArrayList(*Task),
    allocator: std.mem.Allocator,
    is_running: bool,
    next_task_id: u64,

    /// Create a new single-threaded executor
    pub fn init(allocator: std.mem.Allocator) !SingleThreadedExecutor {
        return SingleThreadedExecutor{
            .ready_tasks = std.PriorityQueue(*Task, void, taskCompareFn).init(allocator, {}),
            .pending_tasks = std.ArrayList(*Task).init(allocator),
            .allocator = allocator,
            .is_running = false,
            .next_task_id = 0,
        };
    }

    pub fn deinit(self: *SingleThreadedExecutor) void {
        self.ready_tasks.deinit();
        self.pending_tasks.deinit();
        self.allocator = null; // Clear allocator reference
    }

    pub fn spawn(self: *SingleThreadedExecutor, task: Task) !TaskHandle {
        // Allocate memory for a new task.
        const task_ptr = try self.allocator.create(Task);
        // Remove defer - we're keeping this allocation!
        // defer self.allocator.destroy(task_ptr);

        // Copy the task
        task_ptr.* = task;

        // Update task properties
        task_ptr.id = self.next_task_id;
        self.next_task_id += 1;
        task_ptr.state = .Ready;
        task_ptr.priority = .Normal;

        // Add to the ready queue
        try self.ready_tasks.add(task_ptr);

        // Return a handle to the task
        return TaskHandle{ .id = task_ptr.id };
    }
};
