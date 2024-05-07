temp: std.ArrayList(u8),
inner: std.mem.SplitIterator(u8, .scalar),

const Query_Iterator = @This();

pub const Query_Param = struct {
    name: []const u8,
    value: ?[]const u8,
};

pub fn init(allocator: std.mem.Allocator, query: []const u8) Query_Iterator {
    const params = if (std.mem.startsWith(u8, query, "?")) query[1..] else query;
    return .{
        .allocator = allocator,
        .inner = std.mem.splitScalar(u8, params, '&'),
        .last = null,
    };
}

pub fn deinit(self: *Query_Iterator) void {
    self.temp.deinit();
}

pub fn next(self: *Query_Iterator) !?Query_Param {
    if (self.inner.next()) |entry| {
        self.temp.clearRetainingCapacity();
        if (std.mem.indexOfScalar(u8, entry, '=')) |end_of_name| {
            var name = try percent_encoding.decode_append(&self.temp, entry[0..end_of_name]);
            const value = try percent_encoding.decode_append(&self.temp, entry[end_of_name + 1 ..]);
            if (name.ptr != entry.ptr) {
                // decoding `value` may have enlarged self.temp.items, causing its address to change
                name.ptr = self.temp.items.ptr;
            }
            return .{
                .name = name,
                .value = value,
            };
        } else {
            return .{
                .name = try percent_encoding.decode_append(&self.temp, entry),
                .value = null,
            };
        }
    }
    return null;
}

const percent_encoding = @import("percent_encoding.zig");
const std = @import("std");
