const std = @import("std");

/// Represents the state of a task in the Zuki runtime.
/// This is a union type that can either be `Ready` with a value of type `
/// T`, or `Pending` with no value.
pub fn Poll(comptime T: type) type {
    return union(enum) {
        Ready: T,
        Pending: void,
    };
}
