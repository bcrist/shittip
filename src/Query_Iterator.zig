temp: std.ArrayList(u8),
inner: std.mem.SplitIterator(u8, .scalar),

const Query_Iterator = @This();

pub const Query_Param = @import("Query_Param.zig");

pub fn init(allocator: std.mem.Allocator, query: []const u8) Query_Iterator {
    const params = if (std.mem.startsWith(u8, query, "?")) query[1..] else query;
    return .{
        .temp = std.ArrayList(u8).init(allocator),
        .inner = std.mem.splitScalar(u8, params, '&'),
    };
}

pub fn reset(self: *Query_Iterator) void {
    self.temp.clearRetainingCapacity();
    self.inner.index = 0;
}

pub fn deinit(self: *Query_Iterator) void {
    self.temp.deinit();
}

pub fn next(self: *Query_Iterator) !?Query_Param {
    if (self.inner.next()) |entry| {
        if (entry.len == 0 and self.inner.buffer.len == 0) return null;

        self.temp.clearRetainingCapacity();
        if (std.mem.indexOfScalar(u8, entry, '=')) |end_of_name| {
            var name = try percent_encoding.decode_maybe_append(&self.temp, entry[0..end_of_name], .{});
            const value = try percent_encoding.decode_maybe_append(&self.temp, entry[end_of_name + 1 ..], .{});
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
                .name = try percent_encoding.decode_maybe_append(&self.temp, entry, .{}),
                .value = null,
            };
        }
    }
    return null;
}

const percent_encoding = @import("percent_encoding");
const std = @import("std");
