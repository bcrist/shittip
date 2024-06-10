raw_temp: std.ArrayList(u8),
decode_temp: std.ArrayList(u8),
temp_consumed: bool,
reader: std.io.AnyReader,

const Query_Reader = @This();

pub const Query_Param = @import("Query_Param.zig");

pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader) !Query_Reader {
    var self: Query_Reader = .{
        .raw_temp = std.ArrayList(u8).init(allocator),
        .decode_temp = std.ArrayList(u8).init(allocator),
        .temp_consumed = undefined,
        .reader = undefined,
    };
    try self.reset(reader);
    return self;
}

pub fn reset(self: *Query_Reader, reader: std.io.AnyReader) !void {
    self.raw_temp.clearRetainingCapacity();
    self.decode_temp.clearRetainingCapacity();
    self.temp_consumed = false;
    self.reader = reader;

    const first_byte = reader.readByte() catch |err| switch (err) {
        error.EndOfStream => {
            self.temp_consumed = true;
            return;
        },
        else => return err,
    };

    if (first_byte != '?') {
        try self.raw_temp.append(first_byte);
    }

    reader.streamUntilDelimiter(self.raw_temp.writer(), '&', null) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };
}

pub fn deinit(self: *Query_Reader) void {
    self.raw_temp.deinit();
    self.decode_temp.deinit();
}

pub fn next(self: *Query_Reader) !?Query_Param {
    if (self.temp_consumed or self.raw_temp.items.len == 0) {
        self.temp_consumed = false;
        self.raw_temp.clearRetainingCapacity();
        self.decode_temp.clearRetainingCapacity();
        self.reader.streamUntilDelimiter(self.raw_temp.writer(), '&', null) catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };
    }

    self.temp_consumed = true;
    const entry = self.raw_temp.items;
    if (entry.len == 0) return null;

    if (std.mem.indexOfScalar(u8, entry, '=')) |end_of_name| {
        var name = try percent_encoding.decode_maybe_append(&self.decode_temp, entry[0..end_of_name], .{});
        const value = try percent_encoding.decode_maybe_append(&self.decode_temp, entry[end_of_name + 1 ..], .{});
        if (name.ptr != entry.ptr) {
            // decoding `value` may have enlarged self.decode_temp.items, causing its address to change
            name.ptr = self.decode_temp.items.ptr;
        }
        return .{
            .name = name,
            .value = value,
        };
    } else {
        return .{
            .name = try percent_encoding.decode_maybe_append(&self.decode_temp, entry, .{}),
            .value = null,
        };
    }
}

const percent_encoding = @import("percent_encoding");
const std = @import("std");
