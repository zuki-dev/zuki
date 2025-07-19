const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const NodeList = node_mod.Node.List;

/// Lock-free queue for task scheduling
pub const LockFreeQueue = struct {
    /// Stack pointer with control flags packed in low bits
    stack: Atomic(usize) = Atomic(usize).init(0),

    cache: ?*Node = null,

    metrics: struct {
        push_retries: Atomic(u64) = Atomic(u64).init(0),
        consumer_contentions: Atomic(u64) = Atomic(u64).init(0),
        cache_hits: Atomic(u64) = Atomic(u64).init(0),
        cache_misses: Atomic(u64) = Atomic(u64).init(0),
        total_pushes: Atomic(u64) = Atomic(u64).init(0),
        total_pops: Atomic(u64) = Atomic(u64).init(0),
    } = .{},

    adaptive: struct {
        high_contention_threshold: u64 = 1000,
        retry_backoff_enabled: bool = false,
        last_contention_check: Atomic(u64) = Atomic(u64).init(0),
    } = .{},

    // Control flags stored in the lower bits of the stack pointer
    const HAS_CACHE: usize = 0b01;
    const IS_CONSUMING: usize = 0b10;
    const PTR_MASK: usize = ~(HAS_CACHE | IS_CONSUMING);

    // Ensure Node alignment is sufficient for our bit tricks
    comptime {
        assert(@alignOf(Node) >= ((IS_CONSUMING | HAS_CACHE) + 1));
    }

    /// Push a list of nodes to the queue
    pub fn push(self: *LockFreeQueue, list: NodeList) void {
        var stack = self.stack.load(.monotonic);
        var retry_count: u32 = 0;
        const max_retries_before_backoff = 8;

        // Update metrics
        _ = self.metrics.total_pushes.fetchAdd(1, .monotonic);

        while (true) {
            // Link the list to the current stack top
            list.tail.next = @as(?*Node, @ptrFromInt(stack & PTR_MASK));

            // Create new stack value with the list head as the new top
            var new_stack = @intFromPtr(list.head);
            assert(new_stack & ~PTR_MASK == 0); // Ensure alignment
            new_stack |= (stack & ~PTR_MASK); // Preserve control flags

            // Try to atomically update the stack
            // Release barrier ensures list linking happens before stack update
            if (self.stack.cmpxchgWeak(
                stack,
                new_stack,
                .release,
                .monotonic,
            )) |new_value| {
                stack = new_value;
                retry_count += 1;

                // Update retry metrics
                if (retry_count > 1) {
                    _ = self.metrics.push_retries.fetchAdd(1, .monotonic);
                }

                // Backoff under high contention
                if (retry_count > max_retries_before_backoff and self.adaptive.retry_backoff_enabled) {
                    self.adaptiveBackoff(retry_count);
                }

                continue;
            } else {
                break; // Success!
            }
        }
    }

    /// Push a single node to the queue
    pub fn pushNode(self: *LockFreeQueue, node: *Node) void {
        const list = NodeList.fromNode(node);
        self.push(list);
    }

    /// Backoff strategy for high contention scenarios
    fn adaptiveBackoff(self: *LockFreeQueue, retry_count: u32) void {
        _ = self; // Mark as used

        // Exponential backoff with jitter
        const base_delay = @min(retry_count, 16); // Cap at 16
        const delay_cycles = (@as(u64, 1) << @intCast(base_delay)) + (retry_count % 7); // Add jitter

        // CPU pause/yield for the calculated delay
        var i: u64 = 0;
        while (i < delay_cycles) : (i += 1) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn tryAcquireConsumer(self: *LockFreeQueue) error{ Empty, Contended }!?*Node {
        var stack = self.stack.load(.monotonic);
        var contention_detected = false;

        while (true) {
            // Check if another consumer is already active
            if (stack & IS_CONSUMING != 0) {
                if (!contention_detected) {
                    _ = self.metrics.consumer_contentions.fetchAdd(1, .monotonic);
                    contention_detected = true;
                }
                return error.Contended;
            }

            // Check if queue is empty (no cache and no stack)
            if (stack & (HAS_CACHE | PTR_MASK) == 0) {
                return error.Empty;
            }

            // Prepare new stack state: mark as consuming, set cache flag
            var new_stack = stack | HAS_CACHE | IS_CONSUMING;

            // If cache is empty, consume the stack
            if (stack & HAS_CACHE == 0) {
                assert(stack & PTR_MASK != 0);
                new_stack &= ~PTR_MASK; // Clear the stack pointer
            }

            // Try to acquire consumer status
            // Acquire barrier ensures we see all updates from previous consumers
            if (self.stack.cmpxchgWeak(
                stack,
                new_stack,
                .acquire,
                .monotonic,
            )) |new_value| {
                stack = new_value;
            } else {
                // Success! Return cached node or grab from stack
                return self.cache orelse @as(*Node, @ptrFromInt(stack & PTR_MASK));
            }

            // CAS failed, retry
        }
    }

    /// Release consumer status and update cache
    pub fn releaseConsumer(self: *LockFreeQueue, consumer_cache: ?*Node) void {
        // Determine what flags to remove
        var remove = IS_CONSUMING;
        if (consumer_cache == null) {
            remove |= HAS_CACHE; // No cache to preserve
        }

        // Update cache and release consumer status
        self.cache = consumer_cache;

        // Release barrier ensures cache update happens before releasing consumer status
        const prev_stack = self.stack.fetchSub(remove, .release);
        assert(prev_stack & remove != 0); // Ensure we were actually consuming
    }

    pub fn popFromConsumer(self: *LockFreeQueue, consumer_ref: *?*Node) ?*Node {
        // Try cache first (fast path)
        if (consumer_ref.*) |node| {
            consumer_ref.* = node.next;
            _ = self.metrics.cache_hits.fetchAdd(1, .monotonic);
            return node;
        }

        // Cache miss - record it
        _ = self.metrics.cache_misses.fetchAdd(1, .monotonic);

        // Check if there are nodes in the stack to grab
        var stack = self.stack.load(.monotonic);
        assert(stack & IS_CONSUMING != 0); // We must be the consumer

        if (stack & PTR_MASK == 0) {
            return null; // No nodes in stack
        }

        // Grab all nodes from stack with acquire barrier to see node links
        stack = self.stack.swap(HAS_CACHE | IS_CONSUMING, .acquire);
        assert(stack & IS_CONSUMING != 0);
        assert(stack & PTR_MASK != 0);

        // Extract the first node and cache the rest
        const node = @as(*Node, @ptrFromInt(stack & PTR_MASK));
        consumer_ref.* = node.next;
        return node;
    }

    pub fn pop(self: *LockFreeQueue) ?*Node {
        // Update pop metrics
        _ = self.metrics.total_pops.fetchAdd(1, .monotonic);

        // Try to become the exclusive consumer
        var consumer_cache = self.tryAcquireConsumer() catch return null;
        defer self.releaseConsumer(consumer_cache);

        // Pop from our consumer cache/stack
        return self.popFromConsumer(&consumer_cache);
    }

    /// Check if the queue appears empty (may have false negatives due to concurrency)
    pub fn isEmpty(self: *LockFreeQueue) bool {
        const stack = self.stack.load(.monotonic);
        return (stack & (HAS_CACHE | PTR_MASK)) == 0;
    }

    /// Get approximate size (expensive operation, mainly for debugging)
    pub fn approxSize(self: *LockFreeQueue) usize {
        const stack = self.stack.load(.monotonic);
        var count: usize = 0;

        // Count cached node
        if (stack & HAS_CACHE != 0 and self.cache != null) {
            count += 1;
        }

        // Count nodes in stack
        var current = @as(?*Node, @ptrFromInt(stack & PTR_MASK));
        while (current) |node| : (current = node.next) {
            count += 1;
        }

        return count;
    }

    pub fn getMetrics(self: *LockFreeQueue) QueueMetrics {
        return QueueMetrics{
            .total_pushes = self.metrics.total_pushes.load(.monotonic),
            .total_pops = self.metrics.total_pops.load(.monotonic),
            .push_retries = self.metrics.push_retries.load(.monotonic),
            .consumer_contentions = self.metrics.consumer_contentions.load(.monotonic),
            .cache_hits = self.metrics.cache_hits.load(.monotonic),
            .cache_misses = self.metrics.cache_misses.load(.monotonic),
        };
    }

    /// Reset all performance counters
    pub fn resetMetrics(self: *LockFreeQueue) void {
        self.metrics.total_pushes.store(0, .monotonic);
        self.metrics.total_pops.store(0, .monotonic);
        self.metrics.push_retries.store(0, .monotonic);
        self.metrics.consumer_contentions.store(0, .monotonic);
        self.metrics.cache_hits.store(0, .monotonic);
        self.metrics.cache_misses.store(0, .monotonic);
    }

    /// Enable or disable adaptive backoff based on contention levels
    pub fn updateAdaptiveBehavior(self: *LockFreeQueue) void {
        const metrics = self.getMetrics();
        const total_operations = metrics.total_pushes + metrics.total_pops;

        if (total_operations > 1000) { // Only adapt after sufficient operations
            const contention_ratio = metrics.push_retries * 100 / metrics.total_pushes;
            self.adaptive.retry_backoff_enabled = contention_ratio > 10; // Enable if >10% retry rate
        }
    }

    /// Get cache hit ratio as percentage
    pub fn getCacheHitRatio(self: *LockFreeQueue) f32 {
        const hits = self.metrics.cache_hits.load(.monotonic);
        const misses = self.metrics.cache_misses.load(.monotonic);
        const total = hits + misses;

        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(total)) * 100.0;
    }

    /// Check if queue is experiencing high contention
    pub fn isHighContention(self: *LockFreeQueue) bool {
        const metrics = self.getMetrics();
        const total_operations = metrics.total_pushes + metrics.total_pops;

        if (total_operations < 100) return false; // Not enough data

        const retry_ratio = metrics.push_retries * 100 / metrics.total_pushes;
        const contention_ratio = metrics.consumer_contentions * 100 / metrics.total_pops;

        return retry_ratio > 15 or contention_ratio > 20;
    }

    /// Performance metrics structure
    pub const QueueMetrics = struct {
        total_pushes: u64,
        total_pops: u64,
        push_retries: u64,
        consumer_contentions: u64,
        cache_hits: u64,
        cache_misses: u64,
    };
};

test "LockFreeQueue basic operations" {
    var queue = LockFreeQueue{};

    // Test empty queue
    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.pop() == null);
    try std.testing.expect(queue.approxSize() == 0);

    // Create some test nodes
    var node1 = Node{};
    var node2 = Node{};
    var node3 = Node{};

    // Test single push/pop
    queue.pushNode(&node1);
    try std.testing.expect(!queue.isEmpty());
    try std.testing.expect(queue.approxSize() >= 1);

    const popped1 = queue.pop();
    try std.testing.expect(popped1 == &node1);
    try std.testing.expect(queue.isEmpty());

    // Test multiple push/pop
    queue.pushNode(&node1);
    queue.pushNode(&node2);
    queue.pushNode(&node3);
    try std.testing.expect(queue.approxSize() >= 3);

    // Pop all nodes (order might vary due to LIFO nature)
    var popped_count: usize = 0;
    while (queue.pop()) |_| {
        popped_count += 1;
    }
    try std.testing.expect(popped_count == 3);
    try std.testing.expect(queue.isEmpty());
}

test "LockFreeQueue list operations" {
    var queue = LockFreeQueue{};

    var node1 = Node{};
    var node2 = Node{};
    var node3 = Node{};

    // Create a list and push it
    var list = NodeList.fromNode(&node1);
    list.append(NodeList.fromNode(&node2));
    list.append(NodeList.fromNode(&node3));

    queue.push(list);
    try std.testing.expect(queue.approxSize() >= 3);

    // Pop all nodes
    var popped_count: usize = 0;
    while (queue.pop()) |_| {
        popped_count += 1;
    }
    try std.testing.expect(popped_count == 3);
}

test "LockFreeQueue performance features and metrics" {
    var queue = LockFreeQueue{};

    // Test metrics initialization
    var metrics = queue.getMetrics();
    try std.testing.expect(metrics.total_pushes == 0);
    try std.testing.expect(metrics.total_pops == 0);
    try std.testing.expect(metrics.cache_hits == 0);

    // Create test nodes
    var node1 = Node{};
    var node2 = Node{};
    var node3 = Node{};

    // Test push metrics
    queue.pushNode(&node1);
    queue.pushNode(&node2);
    queue.pushNode(&node3);

    metrics = queue.getMetrics();
    try std.testing.expect(metrics.total_pushes == 3);

    // Test pop metrics and cache behavior
    _ = queue.pop();
    _ = queue.pop();

    metrics = queue.getMetrics();
    try std.testing.expect(metrics.total_pops == 2);

    // Test cache hit ratio calculation
    const hit_ratio = queue.getCacheHitRatio();
    try std.testing.expect(hit_ratio >= 0.0 and hit_ratio <= 100.0);

    // Test contention detection (should be low for single-threaded test)
    try std.testing.expect(!queue.isHighContention());

    // Test adaptive behavior update
    queue.updateAdaptiveBehavior();

    // Test metrics reset
    queue.resetMetrics();
    metrics = queue.getMetrics();
    try std.testing.expect(metrics.total_pushes == 0);
    try std.testing.expect(metrics.total_pops == 0);
}
