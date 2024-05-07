const Token = union (enum) {
    text: []const u8,
    replacement: []const u8,
    open: []const u8,
    other,
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
            } else if (contents.len == 1 and contents[0] == ':') {
                return .other;
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

pub const Render_Options = struct {
    resource_content: *const fn ([]const u8) anyerror![]const u8,
    resource_path: *const fn ([]const u8) anyerror![]const u8,
};

pub fn render(source: []const u8, data: anytype, writer: anytype, options: Render_Options) anyerror!void {
    var iter = Iterator { .remaining = source };
    try render_block(&iter, data, writer, options, false);
}

fn render_block(iter: *Iterator, data: anytype, writer: anytype, options: Render_Options, initial_skip: bool) anyerror!void {
    var skip = initial_skip;
    while (iter.next()) |token| switch (token) {
        .text => |str| {
            if (!skip) try writer.writeAll(str);
        },
        .replacement => |str| {
            if (!skip) try render_replacement(str, data, writer, options);
        },
        .open => |str| {
            if (skip) {
                skip_block(iter);
            } else {
                try render_open_struct(iter, str, data, writer, options);
            }
        },
        .other => skip = !skip,
        .close => return,
    };
}

fn skip_block(iter: *Iterator) void {
    while (iter.next()) |token| switch (token) {
        .text, .replacement, .other => {},
        .open => skip_block(iter),
        .close => return,
    };
}

fn render_replacement(syntax: []const u8, data: anytype, writer: anytype, options: Render_Options) anyerror!void {
    var iter = std.mem.tokenizeAny(u8, syntax, &std.ascii.whitespace);
    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "@resource")) {
            const path = iter.next() orelse {
                log.err("Expected path after @resource", .{});
                return error.TemplateSyntax;
            };
            try writer.writeAll(try options.resource_path(path));
        } else if (std.mem.eql(u8, token, "@include")) {
            const path = iter.next() orelse {
                log.err("Expected path after @include", .{});
                return error.TemplateSyntax;
            };
            try render(try options.resource_content(path), data, writer, options);
        } else if (std.mem.eql(u8, token, "@raw")) {
            const name = iter.next() orelse {
                log.err("Expected field name or * after @raw", .{});
                return error.TemplateSyntax;
            };
            try render_field_or_value(name, data, writer, true);
        } else {
            try render_field_or_value(token, data, writer, false);
        }
    }
}

fn render_field_or_value(name: []const u8, data: anytype, writer: anytype, raw: bool) anyerror!void {
    const T = @TypeOf(data);
    if (std.mem.eql(u8, name, "*")) {
        try render_value(data, writer, raw);
    } else if (@typeInfo(T) == .Struct) {
        inline for (@typeInfo(T).Struct.fields) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                try render_value(@field(data, field.name), writer, raw);
            }
        }
    } else {
        log.err("Field access requires data to be a struct; found {s}", .{ @typeName(@TypeOf(data)) });
        return error.TemplateSyntax;
    }
}

fn render_value(value: anytype, writer: anytype, raw: bool) anyerror!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Pointer => |info| {
            if (info.size == .Slice) {
                if (info.child == u8) {
                    try render_string(value, writer, raw);
                } else {
                    try writer.print("{any}", .{ value });
                }
            } else {
                try render_value(value.*, writer, raw);
            }
        },
        .Array => |info| {
            if (info.child == u8) {
                try render_string(&value, writer, raw);
            } else {
                try writer.print("{any}", .{ &value });
            }
        },
        .Optional => {
            if (value) |v| try render_value(v, writer, raw);
        },
        .Union => switch (value) {
            inline else => |v| try render_value(v, writer, raw),
        },
        .Bool => {
            try writer.writeAll(if (value) "true" else "false");
        },
        .Int, .ComptimeInt, .Vector => {
            try writer.print("{}", .{ value });
        },
        .Float, .ComptimeFloat => {
            try writer.print("{d}", .{ value });
        },
        .Enum, .EnumLiteral => {
            try writer.print("{s}", .{ @tagName(value) });
        },
        else => {
            log.err("Expected value, but found {s}", .{ @typeName(T) });
            return error.TemplateSyntax;
        },
    }
}

fn render_string(str: []const u8, writer: anytype, raw: bool) anyerror!void {
    if (raw) {
        try writer.writeAll(str);
    } else {
        var iter = std.mem.splitAny(u8, str, "&<>\"'");
        while (iter.next()) |chunk| {
            try writer.writeAll(chunk);
            if (iter.index) |i| {
                try writer.writeAll(switch (iter.buffer[i-1]) {
                    '&' => "&amp;",
                    '<' => "&lt;",
                    '>' => "&gt;",
                    '"' => "&quot;",
                    '\'' => "&#39;",
                    else => unreachable,
                });
            }
        }
    }
}

fn render_open_struct(iter: *Iterator, name: []const u8, data: anytype, writer: anytype, options: Render_Options) anyerror!void {
    const T = @TypeOf(data);
    var found_field = false;
    if (@typeInfo(T) == .Struct) {
        inline for (@typeInfo(T).Struct.fields) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                try render_open_value(iter, @field(data, field.name), writer, options);
                found_field = true;
            }
        }
    }
    if (!found_field) {
        log.err("No field named {s} found in {s}", .{ name, @typeName(T) });
        return error.TemplateSyntax;
    }
}

fn render_open_value(iter: *Iterator, value: anytype, writer: anytype, options: Render_Options) anyerror!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Pointer => |info| {
            if (info.size == .Slice) {
                for (value) |v| {
                    var iter_copy = iter.*;
                    try render_block(&iter_copy, v, writer, options, false);
                }
                skip_block(iter);
            } else {
                try render_open_value(iter, value.*, writer, options);
            }
        },
        .Array => {
            for (value) |v| {
                var iter_copy = iter.*;
                try render_block(&iter_copy, v, writer, options, false);
            }
            skip_block(iter);
        },
        .Optional => {
            if (value) |v| {
                try render_block(iter, v, writer, options, false);
            } else {
                try render_block(iter, {}, writer, options, true);
            }
        },
        .Bool => {
            try render_block(iter, value, writer, options, !value);
        },
        else => {
            try render_block(iter, value, writer, options, false);
        },
    }
}

const log = std.log.scoped(.template);
const std = @import("std");
