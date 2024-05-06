const Resource_Path_Func = *const fn ([]const u8) anyerror![]const u8;

const Token = union (enum) {
    text: []const u8,
    replacement: []const u8,
    open: []const u8,
    close,
};

const Iterator = struct {
    remaining: []const u8,

    pub fn next(self: *Iterator) ?Token {
        const remaining = self.remaining;
        if (std.mem.indexOf(u8, remaining, "{{")) |brackets_open| {
            if (brackets_open > 0) {
                self.remaining = remaining[brackets_open..];
                return .{ .text = remaining[0..brackets_open] };
            }
            const brackets_close = std.mem.indexOf(u8, remaining, "}}") orelse remaining.len;
            const contents = remaining[2..brackets_close];
            self.remaining = remaining[@min(remaining.len, brackets_close + 2) ..];

            if (contents.len == 1 and contents[0] == '~') {
                return .close;
            } else if (std.mem.endsWith(u8, contents, "?")) {
                return .{ .open = contents[0 .. contents.len - 1] };
            } else {
                return .{ .replacement = contents };
            }
        } else if (remaining.len > 0) {
            self.remaining = "";
            return .{ .text = remaining };
        } else {
            return null;
        }
    }
};

pub fn render(source: []const u8, data: anytype, writer: anytype, resource_path: Resource_Path_Func) !void {
    var iter = Iterator { .remaining = source };
    try render_block(&iter, data, writer, resource_path);
}

fn render_block(iter: *Iterator, data: anytype, writer: anytype, resource_path: Resource_Path_Func) !void {
    while (iter.next()) |token| switch (token) {
        .text => |str| try writer.writeAll(str),
        .replacement => |str| try render_replacement(str, data, writer, resource_path),
        .open => |str| try render_open_struct(iter, str, data, writer, resource_path),
        .close => return,
    };
}

fn skip_block(iter: *Iterator) void {
    while (iter.next()) |token| switch (token) {
        .text, .replacement => {},
        .open => skip_block(iter),
        .close => return,
    };
}

fn render_replacement(syntax: []const u8, data: anytype, writer: anytype, resource_path: Resource_Path_Func) !void {
    const T = @TypeOf(data);
    var iter = std.mem.tokenizeAny(u8, syntax, &std.ascii.whitespace);
    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "@resource")) {
            const path = iter.next() orelse return error.TemplateSyntax;
            try writer.writeAll(try resource_path(path));
        } else if (std.mem.eql(u8, token, "*")) {
            try render_value(data, writer);
        } else if (@typeInfo(T) == .Struct) {
            inline for (@typeInfo(T).Struct.fields) |field| {
                if (std.mem.eql(u8, token, field.name)) {
                    try render_value(@field(data, field.name), writer);
                }
            }
        } else return error.TemplateSyntax;
    }
}

fn render_value(value: anytype, writer: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Pointer => |info| {
            if (info.size == .Slice) {
                if (info.child == u8) {
                    try writer.print("{s}", .{ value });
                } else {
                    try writer.print("{any}", .{ value });
                }
            } else {
                try render_value(value.*, writer);
            }
        },
        .Optional => {
            if (value) |v| try render_value(v, writer);
        },
        else => {
            try writer.print("{}", .{ value });
        },
    }
}

fn render_open_struct(iter: *Iterator, syntax: []const u8, data: anytype, writer: anytype, resource_path: Resource_Path_Func) !void {
    const T = @TypeOf(data);
    var found_field = false;
    if (@typeInfo(T) == .Struct) {
        inline for (@typeInfo(T).Struct.fields) |field| {
            if (std.mem.eql(u8, syntax, field.name)) {
                try render_open_value(iter, @field(data, field.name), writer, resource_path);
                found_field = true;
            }
        }
    }
    if (!found_field) return error.TemplateSyntax;
}

fn render_open_value(iter: *Iterator, value: anytype, writer: anytype, resource_path: Resource_Path_Func) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Pointer => |info| {
            if (info.size == .Slice) {
                for (value) |v| {
                    var iter_copy = iter.*;
                    try render_block(&iter_copy, v, writer, resource_path);
                }
                skip_block(iter);
            } else {
                try render_open_value(value.*, writer);
            }
        },
        .Array => {
            for (value) |v| {
                var iter_copy = iter.*;
                try render_block(&iter_copy, v, writer, resource_path);
            }
            skip_block(iter);
        },
        .Optional => {
            if (value) |v| {
                try render_block(iter, v, writer, resource_path);
            } else {
                skip_block(iter);
            }
        },
        .Bool => {
            if (value) {
                try render_block(iter, value, writer, resource_path);
            } else {
                skip_block(iter);
            }
        },
        else => {
            try render_block(iter, value, writer, resource_path);
        },
    }
}

const log = std.log.scoped(.template);
const std = @import("std");
