allocator: std.mem.Allocator,
reader: *std.Io.Reader,
raw: std.ArrayList(u8),
raw_consumed: bool,
end_of_stream_reached: bool,
temp: std.ArrayList(u8),

const Query_Reader = @This();

pub const Query_Param = @import("Query_Param.zig");

pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Query_Reader {
    var self: Query_Reader = .{
        .allocator = allocator,
        .reader = undefined,
        .raw = .empty,
        .raw_consumed = undefined,
        .end_of_stream_reached = undefined,
        .temp = .empty,
    };
    try self.reset(reader);
    return self;
}

pub fn reset(self: *Query_Reader, reader: *std.Io.Reader) !void {
    self.raw.clearRetainingCapacity();
    self.temp.clearRetainingCapacity();
    self.raw_consumed = false;
    self.end_of_stream_reached = false;
    self.reader = reader;

    const first_byte = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => {
            self.raw_consumed = true;
            self.end_of_stream_reached = true;
            return;
        },
        else => return err,
    };

    if (first_byte != '?') {
        try self.raw.append(first_byte);
    }

    var raw_writer = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.raw);
    defer self.raw = raw_writer.toArrayList();

    reader.streamDelimiter(&raw_writer.writer, '&') catch |err| switch (err) {
        error.EndOfStream => {
            self.end_of_stream_reached = true;
            return;
        },
        else => return err,
    };

    reader.toss(1); // &
}

pub fn deinit(self: *Query_Reader) void {
    self.raw.deinit(self.allocator);
    self.temp.deinit(self.allocator);
}

pub fn next(self: *Query_Reader) !?Query_Param {
    if (self.raw_consumed or self.raw.items.len == 0) done: {
        self.raw_consumed = false;
        self.raw.clearRetainingCapacity();
        self.temp.clearRetainingCapacity();

        var raw_writer = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.raw);
        defer self.raw = raw_writer.toArrayList();

        self.reader.streamDelimiter(&raw_writer.writer, '&') catch |err| switch (err) {
            error.EndOfStream => {
                self.end_of_stream_reached = true;
                break :done {};
            },
            else => return err,
        };

        self.reader.toss(1); // &
    }

    self.raw_consumed = true;
    const entry = self.raw.items;
    if (entry.len == 0 and self.end_of_stream_reached) return null;

    if (std.mem.indexOfScalar(u8, entry, '=')) |end_of_name| {
        var name = try percent_encoding.decode_maybe_append(&self.temp, entry[0..end_of_name], .default);
        const value = try percent_encoding.decode_maybe_append(&self.temp, entry[end_of_name + 1 ..], .default);
        if (name.ptr != entry.ptr) {
            // decoding `value` may have enlarged self.decode_temp.items, causing its address to change
            name.ptr = self.temp.items.ptr;
        }
        return .{
            .name = name,
            .value = value,
        };
    } else {
        return .{
            .name = try percent_encoding.decode_maybe_append(&self.temp, entry, .default),
            .value = null,
        };
    }
}

const percent_encoding = @import("percent_encoding");
const std = @import("std");
