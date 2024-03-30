/// For use with headers ETag, If-Match, If-None-Match, etc.

remaining: []const u8,

pub const Result = struct {
    weak: bool,
    value: []const u8,
};

pub fn next(self: *@This()) !?Result {
    var remaining = std.mem.trimLeft(u8, self.remaining, &std.ascii.whitespace);
    if (remaining.len == 0) return null;

    var result: Result = .{
        .weak = false,
        .value = "",
    };

    if (std.mem.startsWith(u8, remaining, "W/")) {
        result.weak = true;
        remaining = remaining[2..];
    }

    if (!std.mem.startsWith(u8, remaining, "\"")) {
        return error.BadRequest;
    }

    remaining = remaining[1..];

    if (std.mem.indexOfScalar(u8, remaining, '"')) |end| {
        result.value = remaining[0..end];
        remaining = remaining[end + 1 ..];
    } else return error.BadRequest;

    remaining = std.mem.trimLeft(u8, self.remaining, &std.ascii.whitespace);

    if (std.mem.startsWith(u8, remaining, ",")) {
        remaining = remaining[1..];
    }

    self.remaining = remaining;
    return result;
}

const std = @import("std");
