// lib/list — intrusive doubly-linked list analog to Linux list_head
pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();
        head: ?*T = null,
        tail: ?*T = null,
        len: usize = 0,

        pub fn pushBack(self: *Self, node: *T, next_field: []const u8, prev_field: []const u8) void {
            _ = next_field; _ = prev_field;
            _ = self; _ = node;
        }
    };
}
