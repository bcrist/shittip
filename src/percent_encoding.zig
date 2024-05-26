pub const Encode_Options = union (enum) {
    encode_all,
    encode_other,
    encode_other_and_reserved,
    encode_other_and: struct {
        @"!": bool = false,
        @"#": bool = false,
        @"$": bool = false,
        @"&": bool = false,
        @"'": bool = false,
        @"(": bool = false,
        @")": bool = false,
        @"*": bool = false,
        @"+": bool = false,
        @",": bool = false,
        @"/": bool = false,
        @":": bool = false,
        @";": bool = false,
        @"=": bool = false,
        @"?": bool = false,
        @"@": bool = false,
        @"[": bool = false,
        @"]": bool = false,
    },
};
pub fn encode_alloc(allocator: std.mem.Allocator, raw: []const u8, comptime options: Encode_Options) ![]const u8 {
    var iter = encode(raw, options);
    var len: usize = 0;
    while (iter.next()) |part| {
        len += part.len;
    }

    // any percent-encoded bytes will increase the length of the string,
    // so if it's the same length, just dupe the input:
    if (len == raw.len) return allocator.dupe(u8, raw);

    var result = std.ArrayListUnmanaged(u8).initBuffer(try allocator.alloc(u8, len));

    iter = encode(raw, options);
    while (iter.next()) |part| {
        result.appendSliceAssumeCapacity(part);
    }

    return result.items;
}
pub fn encode_maybe_append(list: *std.ArrayList(u8), raw: []const u8, comptime options: Encode_Options) ![]const u8 {
    const prefix_length = list.items.len;
    var iter = encode(raw, options);
    if (iter.next()) |first| {
        if (first.len == raw.len and first.ptr == raw.ptr) {
            return first;
        }
        try list.appendSlice(first);
        while (iter.next()) |part| {
            try list.appendSlice(part);
        }
    }
    return list.items[prefix_length..];
}
pub fn encode_append(list: *std.ArrayList(u8), raw: []const u8, comptime options: Encode_Options) !void {
    var iter = encode(raw, options);
    while (iter.next()) |part| {
        try list.appendSlice(part);
    }
}
pub fn encode(raw: []const u8, comptime options: Encode_Options) Encoder(options) {
    return .{ .remaining = raw };
}
pub fn Encoder(comptime options: Encode_Options) type {
    return struct {
        remaining: []const u8,
        temp: [3]u8 = "%00".*,

        pub fn next(self: *@This()) ?[]const u8 {
            const remaining = self.remaining;
            if (remaining.len == 0) return null;

            for (0.., remaining) |i, c| {
                const should_encode = switch (c) {
                    'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => options == .encode_all,
                    inline '!', '#', '$', '&', '\'', '(', ')', '*', '+', ',', '/', ':', ';', '=', '?', '@', '[', ']' => |cc|
                        switch (options) {
                            .encode_all, .encode_other_and_reserved => true,
                            .encode_other => false,
                            .encode_other_and => |char_flags| @field(char_flags, &.{cc} ),
                        },
                    else => true,
                };

                if (should_encode) {
                    if (i > 0) {
                        self.remaining = remaining[i..];
                        return remaining[0..i];
                    }
                    const temp: []u8 = &self.temp;
                    @memcpy(temp[1..], &std.fmt.bytesToHex(&[_]u8{c}, .upper));
                    self.remaining = remaining[1..];
                    return temp;
                }
            }

            self.remaining = "";
            return remaining;
        }
    };
}

pub fn decode_alloc(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var iter = decode(encoded);
    var len: usize = 0;
    while (iter.next()) |part| {
        len += part.len;
    }

    // any percent-encoded bytes will increase the length of the string,
    // so if it's the same length, just dupe the input:
    if (len == encoded.len) return allocator.dupe(u8, encoded);

    var result = std.ArrayListUnmanaged(u8).initBuffer(try allocator.alloc(u8, len));

    iter = decode(encoded);
    while (iter.next()) |part| {
        result.appendSliceAssumeCapacity(part);
    }

    return result.items;
}
pub fn decode_maybe_append(list: *std.ArrayList(u8), encoded: []const u8) ![]const u8 {
    const prefix_length = list.items.len;
    var iter = decode(encoded);
    if (iter.next()) |first| {
        if (first.len == encoded.len and first.ptr == encoded.ptr) {
            return first;
        }
        try list.appendSlice(first);
        while (iter.next()) |part| {
            try list.appendSlice(part);
        }
    }
    return list.items[prefix_length..];
}
pub fn decode_append(list: *std.ArrayList(u8), encoded: []const u8) !void {
    var iter = decode(encoded);
    while (iter.next()) |part| {
        try list.appendSlice(part);
    }
}
pub fn decode(encoded: []const u8) Decoder {
    return .{ .remaining = encoded };
}
pub const Decoder = struct {
    remaining: []const u8,
    temp: [1]u8 = undefined,

    pub fn next(self: *Decoder) ?[]const u8 {
        const remaining = self.remaining;
        if (remaining.len == 0) return null;

        if (remaining[0] == '%') {
            if (remaining.len >= 3) {
                self.temp[0] = std.fmt.parseInt(u8, remaining[1..3], 16) catch {
                    self.remaining = remaining[1..];
                    return remaining[0..1];
                };
                self.remaining = remaining[3..];
                return &self.temp;
            } else {
                self.remaining = remaining[1..];
                return remaining[0..1];
            }
        }

        if (std.mem.indexOfScalar(u8, remaining, '%')) |end| {
            self.remaining = remaining[end..];
            return remaining[0..end];
        }

        self.remaining = "";
        return remaining;
    }
};

pub fn fmtEncoded(raw: []const u8) std.fmt.Formatter(format) {
    return .{ .data = raw };
}

fn format(raw: []const u8, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
    comptime var encode_options: Encode_Options = .encode_other_and_reserved;

    if (fmt.len > 0) {
        encode_options = .{ .encode_other_and = .{} };
        const ptr = &encode_options.encode_other_and;
        inline for (fmt) |c| switch (c) {
            '!' => ptr.@"!" = true,
            '#' => ptr.@"#" = true,
            '$' => ptr.@"$" = true,
            '&' => ptr.@"&" = true,
            '\'' => ptr.@"'" = true,
            '(' => ptr.@"(" = true,
            ')' => ptr.@")" = true,
            '*' => ptr.@"*" = true,
            '+' => ptr.@"+" = true,
            ',' => ptr.@"," = true,
            '/' => ptr.@"/" = true,
            'c' => ptr.@":" = true,
            ';' => ptr.@";" = true,
            '=' => ptr.@"=" = true,
            '?' => ptr.@"?" = true,
            '@' => ptr.@"@" = true,
            '[' => ptr.@"[" = true,
            ']' => ptr.@"]" = true,
            else => @compileError("invalid percent encoding format: " ++ fmt),
        };
    }

    var encoder = encode(raw, encode_options);
    while (encoder.next()) |chunk| {
        try writer.writeAll(chunk);
    }
}

const std = @import("std");
