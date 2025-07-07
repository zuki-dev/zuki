const std = @import("std");
const Task = @import("../core/mod.zig").Task;
const Future = @import("../core/mod.zig").Future;
const Poll = @import("../core/mod.zig").Poll;
const PollState = @import("../core/mod.zig").PollState;
const Context = @import("../core/mod.zig").Context;
const Waker = @import("../core/mod.zig").Waker;
const TaskHandle = @import("../core/mod.zig").TaskHandle;
const TaskPriority = @import("../core/mod.zig").Priority;
const TaskState = @import("../core/mod.zig").TaskState;

/// Data structure to hold waker state
pub const WakerData = struct {
    executor: *SingleThreadedExecutor,
    task_id: u64,
};

/// Single-threaded executor for running tasks
pub const SingleThreadedExecutor = struct {
    /// Task comparison function for priority queue (higher priority first)
    fn taskCompareFn(_: void, a: *Task, b: *Task) std.math.Order {
        // Higher priority comes first (reverse order)
        return std.math.order(@intFromEnum(b.priority), @intFromEnum(a.priority));
    }

    /// Wake function called by the waker
    fn wakeTask(data: *anyopaque) void {
        const waker_data = @as(*WakerData, @alignCast(@ptrCast(data)));
        waker_data.executor.wake(waker_data.task_id) catch {};
    }

    ready_tasks: std.PriorityQueue(*Task, void, taskCompareFn),
    pending_tasks: std.ArrayList(*Task),
    allocator: std.mem.Allocator,
    is_running: bool,
    next_task_id: u64,
    waker_data_map: std.AutoHashMap(u64, *WakerData),

    /// Create a new single-threaded executor
    pub fn init(allocator: std.mem.Allocator) !SingleThreadedExecutor {
        return SingleThreadedExecutor{
            .ready_tasks = std.PriorityQueue(*Task, void, taskCompareFn).init(allocator, {}),
            .pending_tasks = std.ArrayList(*Task).init(allocator),
            .allocator = allocator,
            .is_running = false,
            .next_task_id = 0,
            .waker_data_map = std.AutoHashMap(u64, *WakerData).init(allocator),
        };
    }

    pub fn deinit(self: *SingleThreadedExecutor) void {
        // Free any allocated waker data
        var waker_iter = self.waker_data_map.valueIterator();
        while (waker_iter.next()) |waker_data_ptr| {
            self.allocator.destroy(waker_data_ptr.*);
        }
        self.waker_data_map.deinit();

        self.ready_tasks.deinit();
        self.pending_tasks.deinit();
    }

    /// Create a waker for a task
    fn createWaker(self: *SingleThreadedExecutor, task_id: u64) !Waker {
        const waker_data = try self.allocator.create(WakerData);
        waker_data.* = WakerData{
            .executor = self,
            .task_id = task_id,
        };

        // Store the waker data so we can free it later
        try self.waker_data_map.put(task_id, waker_data);

        // Create the waker
        return Waker.init(wakeTask, waker_data);
    }

    /// Wake up a task by ID - move it from pending to ready queue
    pub fn wake(self: *SingleThreadedExecutor, task_id: u64) !void {
        // Find the task in pending_tasks
        for (self.pending_tasks.items, 0..) |task, i| {
            if (task.id == task_id) {
                // Move from pending to ready
                task.state = .Ready;
                try self.ready_tasks.add(task);
                _ = self.pending_tasks.swapRemove(i);
                return;
            }
        }
        // If we get here, the task wasn't found or was already ready
    }

    pub fn spawn(self: *SingleThreadedExecutor, task: Task) !TaskHandle {
        // Allocate memory for a new task.
        const task_ptr = try self.allocator.create(Task);

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

    /// Run a single task polling step
    fn poll_task(self: *SingleThreadedExecutor, task: *Task) !bool {
        // Create a waker for this task
        const waker = try self.createWaker(task.id);
        const ctx = Context{ .waker = waker };

        // Mark task as running during poll
        task.state = .Running;

        // Poll the task
        const poll_result = task.poll(ctx);

        // Handle the poll result
        switch (poll_result) {
            .Ready => {
                task.state = .Completed;
                return true; // Task is complete
            },
            .Pending => {
                // Task is still pending, move to pending queue
                task.state = .Pending;
                try self.pending_tasks.append(task);
                return false;
            },
        }
    }

    /// Run the executor until all tasks are completed
    pub fn run(self: *SingleThreadedExecutor) !void {
        if (self.is_running) return error.AlreadyRunning;

        self.is_running = true;
        defer self.is_running = false;

        // Keep running while we have tasks
        while (self.ready_tasks.count() > 0) {
            const task = self.ready_tasks.remove();

            // Skip tasks that are not ready
            if (task.state != .Ready) {
                continue;
            }

            // Poll the task
            _ = try self.poll_task(task);
        }
    }

    /// Run a step of the executor (poll one task)
    pub fn step(self: *SingleThreadedExecutor) !bool {
        if (self.ready_tasks.count() == 0) {
            return false; // No tasks to run
        }

        const task = self.ready_tasks.remove();

        // Skip tasks that are not ready
        if (task.state != .Ready) {
            return true; // More tasks might be available
        }

        // Poll the task
        _ = try self.poll_task(task);

        return self.ready_tasks.count() > 0;
    }
};
