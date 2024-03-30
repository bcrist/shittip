const Resource_Path_Func = *const fn (comptime []const u8) anyerror![]const u8;
const Resource_Path_Func_RT = *const fn ([]const u8) anyerror![]const u8;

pub fn render(comptime source: []const u8, data: anytype, writer: anytype, resource_path: Resource_Path_Func) !void {
    @setEvalBranchQuota(100_000);
    comptime var start = 0;
    inline while (start < source.len) {
        if (comptime std.mem.indexOfPos(u8, source, start, "{{")) |brackets_open| {
            try writer.writeAll(source[start..brackets_open]);
            const brackets_close = std.mem.indexOfPos(u8, source, brackets_open + 2, "}}") orelse source.len;
            const contents = source[brackets_open + 2 .. brackets_close];
            try render_replacement(contents, data, writer, resource_path);
            start = brackets_close + 2;
        } else {
            try writer.writeAll(source[start..]);
            start = source.len;
        }
    }
}

pub fn render_replacement(comptime syntax: []const u8, data: anytype, writer: anytype, resource_path: Resource_Path_Func) !void {
    const T = @TypeOf(data);

    comptime var iter = std.mem.tokenizeAny(u8, syntax, &std.ascii.whitespace);
    inline while (iter.next()) |token| {
        if (comptime std.mem.eql(u8, token, "@resource")) {
            const path = iter.next() orelse @compileError("Expected file path after @resource");
            try writer.writeAll(try resource_path(path));
        } else if (@hasField(T, token)) {
            try writer.print("{}", .{ @field(data, token) });
        } else @compileError("Unknown field: " ++ token);
    }
}


pub fn render_rt(source: []const u8, writer: anytype, resource_path: Resource_Path_Func_RT) !void {
    var start: usize = 0;
    while (start < source.len) {
        if (std.mem.indexOfPos(u8, source, start, "{{")) |brackets_open| {
            try writer.writeAll(source[start..brackets_open]);
            const brackets_close = std.mem.indexOfPos(u8, source, brackets_open + 2, "}}") orelse source.len;
            const contents = source[brackets_open + 2 .. brackets_close];
            try render_replacement_rt(contents, writer, resource_path);
            start = brackets_close + 2;
        } else {
            try writer.writeAll(source[start..]);
            start = source.len;
        }
    }
}

pub fn render_replacement_rt(syntax: []const u8, writer: anytype, resource_path: Resource_Path_Func_RT) !void {
    var iter = std.mem.tokenizeAny(u8, syntax, &std.ascii.whitespace);
    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "@resource")) {
            const path = iter.next() orelse {
                log.err("Expected file path after @resource", .{});
                return error.InvalidTemplate;
            };
            try writer.writeAll(try resource_path(path));
        } else {
            log.err("Unknown field: {s}", .{ token });
            return error.InvalidTemplate;
        }
    }
}

const log = std.log.scoped(.template);
const std = @import("std");
