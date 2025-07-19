const std = @import("std");
const assert = std.debug.assert;

/// Intrusive linked list node for zero-allocation list operations
/// This node is meant to be embedded directly in your data structures
pub const Node = struct {
    next: ?*Node = null,

    /// A linked list of Nodes with head and tail pointers
    pub const List = struct {
        head: *Node,
        tail: *Node,

        /// Create a list from a single node
        pub fn fromNode(node: *Node) List {
            node.next = null;
            return List{
                .head = node,
                .tail = node,
            };
        }

        /// Append another list to the end of this list
        pub fn append(self: *List, other: List) void {
            self.tail.next = other.head;
            self.tail = other.tail;
        }

        /// Prepend another list to the beginning of this list
        pub fn prepend(self: *List, other: List) void {
            other.tail.next = self.head;
            self.head = other.head;
        }

        /// Check if the list contains only one node
        pub fn isSingle(self: List) bool {
            return self.head == self.tail;
        }

        /// Split the list after the given node, returning the second part
        /// The original list will end at split_node, the returned list starts after it
        pub fn splitAfter(self: *List, split_node: *Node) ?List {
            if (split_node.next) |next_node| {
                const second_part = List{
                    .head = next_node,
                    .tail = self.tail,
                };

                // Update the original list
                self.tail = split_node;
                split_node.next = null;

                return second_part;
            }
            return null;
        }

        /// Count the number of nodes in the list (expensive operation)
        pub fn count(self: List) usize {
            var current: ?*Node = self.head;
            var len: usize = 0;

            while (current) |node| : (current = node.next) {
                len += 1;
                if (node == self.tail) break;
            }

            return len;
        }
    };
};

test "Node basic operations" {
    var node1 = Node{};
    var node2 = Node{};
    var node3 = Node{};

    // Test single node list
    var list1 = Node.List.fromNode(&node1);
    try std.testing.expect(list1.head == &node1);
    try std.testing.expect(list1.tail == &node1);
    try std.testing.expect(list1.isSingle());
    try std.testing.expect(list1.count() == 1);

    // Test appending
    const list2 = Node.List.fromNode(&node2);
    list1.append(list2);
    try std.testing.expect(list1.head == &node1);
    try std.testing.expect(list1.tail == &node2);
    try std.testing.expect(!list1.isSingle());
    try std.testing.expect(list1.count() == 2);

    // Test prepending
    const list3 = Node.List.fromNode(&node3);
    list1.prepend(list3);
    try std.testing.expect(list1.head == &node3);
    try std.testing.expect(list1.tail == &node2);
    try std.testing.expect(list1.count() == 3);

    // Test splitting
    if (list1.splitAfter(&node3)) |second_part| {
        try std.testing.expect(list1.head == &node3);
        try std.testing.expect(list1.tail == &node3);
        try std.testing.expect(second_part.head == &node1);
        try std.testing.expect(second_part.tail == &node2);
        try std.testing.expect(list1.count() == 1);
        try std.testing.expect(second_part.count() == 2);
    } else {
        try std.testing.expect(false); // Should not reach here
    }
}
