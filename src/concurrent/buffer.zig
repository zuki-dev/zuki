const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;
const node_mod = @import("node.zig");
const queue_mod = @import("queue.zig");
const Node = node_mod.Node;
const NodeList = node_mod.Node.List;
const LockFreeQueue = queue_mod.LockFreeQueue;

/// A bounded single-producer, multi-consumer ring buffer for work stealing
/// This is used for local task buffers in work-stealing schedulers
pub const RingBuffer = struct {
    head: Atomic(Index) = Atomic(Index).init(0),
    tail: Atomic(Index) = Atomic(Index).init(0),
    array: [CAPACITY]Atomic(*Node) = undefined,

    const Index = u32;
    const CAPACITY = 256; // Must be power of 2 for modulo operations

    comptime {
        assert(std.math.maxInt(Index) >= CAPACITY);
        assert(std.math.isPowerOfTwo(CAPACITY));
    }

    pub fn init() RingBuffer {
        var buffer = RingBuffer{};
        // Initialize all array elements to undefined but valid atomic state
        for (&buffer.array) |*elem| {
            elem.* = Atomic(*Node).init(undefined);
        }
        return buffer;
    }

    /// Result of a steal operation
    pub const StealResult = struct {
        node: *Node,
        pushed_to_buffer: bool, // Whether we pushed additional nodes to our buffer
    };

    /// Push nodes from a list to the buffer
    /// Returns error.Overflow if buffer is full and provides overflowed nodes
    pub fn push(self: *RingBuffer, list: *NodeList) error{Overflow}!void {
        var head = self.head.load(.monotonic);
        var tail = self.tail.load(.unordered); // Only we modify tail

        while (true) {
            const current_size = tail -% head;
            assert(current_size <= CAPACITY);

            // Try to push nodes if there's space
            if (current_size < CAPACITY) {
                var current_node: ?*Node = list.head;
                var local_size = current_size;
                while (local_size < CAPACITY and current_node != null) {
                    const node = current_node.?;
                    current_node = node.next;

                    // Store atomically for steal() readers
                    self.array[tail % CAPACITY].store(node, .unordered);
                    tail +%= 1;
                    local_size += 1;
                }

                // Release barrier ensures array writes are visible before tail update
                self.tail.store(tail, .release);

                // If we pushed all nodes, we're done
                if (current_node == null) {
                    return;
                }

                // Update list to remaining nodes and continue
                list.head = current_node.?;
                std.atomic.spinLoopHint();
                head = self.head.load(.monotonic);
                continue;
            }

            // Buffer is full - try to make room by overflowing half the tasks
            const migrate_count = current_size / 2;

            // Try to atomically advance head to "steal" from ourselves
            if (self.head.cmpxchgWeak(
                head,
                head +% migrate_count,
                .acquire, // Ensure we can safely read array elements
                .monotonic,
            )) |new_head| {
                head = new_head;
            } else {
                // Success! Create a linked list from migrated nodes
                const first_node = self.array[head % CAPACITY].load(.unordered);
                var current_head = head;
                var prev_node: *Node = first_node;

                for (0..migrate_count - 1) |_| {
                    current_head +%= 1;
                    const next_node = self.array[current_head % CAPACITY].load(.unordered);
                    prev_node.next = next_node;
                    prev_node = next_node;
                }

                // Connect migrated nodes to the original list
                prev_node.next = list.head;
                list.head = first_node;

                return error.Overflow;
            }

            // CAS failed, retry with new head value
        }
    }

    /// Pop a node from the buffer (single producer only)
    pub fn pop(self: *RingBuffer) ?*Node {
        var head = self.head.load(.monotonic);
        const tail = self.tail.load(.unordered); // Only we modify tail

        while (true) {
            const current_size = tail -% head;
            assert(current_size <= CAPACITY);

            if (current_size == 0) {
                return null; // Buffer is empty
            }

            // Try to atomically advance head to claim a node
            if (self.head.cmpxchgWeak(
                head,
                head +% 1,
                .acquire, // Ensure we can safely access the claimed node
                .monotonic,
            )) |new_head| {
                head = new_head;
            } else {
                return self.array[head % CAPACITY].load(.unordered);
            }

            // CAS failed, retry with updated head
        }
    }

    /// Consume nodes from a queue into this buffer
    /// Returns a node to execute and whether nodes were added to buffer
    pub fn consume(self: *RingBuffer, queue: *LockFreeQueue) ?StealResult {
        // We should only consume when our buffer is empty
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.unordered);
        const buffer_size = tail -% head;
        assert(buffer_size <= CAPACITY);
        assert(buffer_size == 0); // Buffer should be empty when consuming

        // Try to acquire consumer access to the queue
        var consumer_cache = queue.tryAcquireConsumer() catch return null;
        defer queue.releaseConsumer(consumer_cache);

        // Fill our buffer from the queue
        var pushed: Index = 0;
        while (pushed < CAPACITY) {
            const node = queue.popFromConsumer(&consumer_cache) orelse break;
            self.array[(tail +% pushed) % CAPACITY].store(node, .unordered);
            pushed += 1;
        }

        // Get one more node to return directly, or take one from our buffer
        const return_node = queue.popFromConsumer(&consumer_cache) orelse blk: {
            if (pushed == 0) return null;
            pushed -= 1;
            break :blk self.array[(tail +% pushed) % CAPACITY].load(.unordered);
        };

        // Update buffer tail if we added nodes
        if (pushed > 0) {
            self.tail.store(tail +% pushed, .release);
        }

        return StealResult{
            .node = return_node,
            .pushed_to_buffer = pushed > 0,
        };
    }

    /// Steal work from another buffer
    /// Returns a node to execute and whether nodes were added to our buffer
    pub fn steal(self: *RingBuffer, target: *RingBuffer) ?StealResult {
        // We should only steal when our buffer is empty
        const our_head = self.head.load(.monotonic);
        const our_tail = self.tail.load(.unordered);
        const our_size = our_tail -% our_head;
        assert(our_size <= CAPACITY);
        assert(our_size == 0); // Our buffer should be empty when stealing

        while (true) : (std.atomic.spinLoopHint()) {
            // Load target's head and tail with proper ordering
            const target_head = target.head.load(.acquire);
            const target_tail = target.tail.load(.acquire);

            // Check if target has work to steal
            const target_size = target_tail -% target_head;
            if (target_size > CAPACITY) {
                // Target was modified between loads, retry
                continue;
            }

            // Calculate how much to steal (about half)
            const steal_count = target_size - (target_size / 2);
            if (steal_count == 0) {
                return null; // Nothing to steal
            }

            // Copy nodes from target to our buffer
            for (0..steal_count) |i| {
                const node = target.array[(target_head +% @as(Index, @intCast(i))) % CAPACITY].load(.unordered);
                self.array[(our_tail +% @as(Index, @intCast(i))) % CAPACITY].store(node, .unordered);
            }

            // Try to commit the steal by advancing target's head
            if (target.head.cmpxchgWeak(
                target_head,
                target_head +% steal_count,
                .acq_rel, // Acquire: safe to use stolen nodes, Release: nodes copied before commit
                .monotonic,
            )) |_| {
                // CAS failed, target was modified, try again
                continue;
            } else {
                // Success! Take one node to return and put the rest in our buffer
                const pushed = steal_count - 1;
                const return_node = self.array[(our_tail +% pushed) % CAPACITY].load(.unordered);

                // Update our tail if we kept any nodes
                if (pushed > 0) {
                    self.tail.store(our_tail +% pushed, .release);
                }

                return StealResult{
                    .node = return_node,
                    .pushed_to_buffer = pushed > 0,
                };
            }
        }
    }

    /// Get current size (may be stale due to concurrency)
    pub fn size(self: *RingBuffer) Index {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.monotonic);
        return tail -% head;
    }

    /// Check if buffer appears empty
    pub fn isEmpty(self: *RingBuffer) bool {
        return self.size() == 0;
    }

    /// Check if buffer appears full
    pub fn isFull(self: *RingBuffer) bool {
        return self.size() >= CAPACITY;
    }
};

test "RingBuffer basic operations" {
    var buffer = RingBuffer.init();

    // Test empty buffer
    try std.testing.expect(buffer.isEmpty());
    try std.testing.expect(buffer.pop() == null);
    try std.testing.expect(buffer.size() == 0);

    // Create test nodes
    var node1 = Node{};
    var node2 = Node{};
    var node3 = Node{};

    // Test push/pop with single node list
    var list1 = NodeList.fromNode(&node1);
    try buffer.push(&list1);
    try std.testing.expect(!buffer.isEmpty());
    try std.testing.expect(buffer.size() == 1);

    const popped = buffer.pop();
    try std.testing.expect(popped == &node1);
    try std.testing.expect(buffer.isEmpty());

    // Test push with multiple nodes
    var list2 = NodeList.fromNode(&node1);
    list2.append(NodeList.fromNode(&node2));
    list2.append(NodeList.fromNode(&node3));

    try buffer.push(&list2);
    try std.testing.expect(buffer.size() == 3);

    // Pop all nodes
    var pop_count: usize = 0;
    while (buffer.pop()) |_| {
        pop_count += 1;
    }
    try std.testing.expect(pop_count == 3);
    try std.testing.expect(buffer.isEmpty());
}

test "RingBuffer overflow handling" {
    var buffer = RingBuffer.init();

    // Create enough nodes to fill the buffer
    var nodes: [RingBuffer.CAPACITY + 10]Node = undefined;
    for (&nodes) |*node| {
        node.* = Node{};
    }

    // Create a large list
    var list = NodeList.fromNode(&nodes[0]);
    for (1..nodes.len) |i| {
        list.append(NodeList.fromNode(&nodes[i]));
    }

    // This should overflow
    if (buffer.push(&list)) {
        try std.testing.expect(false); // Should not succeed
    } else |err| {
        try std.testing.expect(err == error.Overflow);
        // Buffer should have some content (at least CAPACITY nodes were processed)
        try std.testing.expect(buffer.size() > 0);
    }
}
