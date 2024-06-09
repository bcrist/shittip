pub const Encode_Type = enum {
    raw,
    percent_encoded,
};
pub const Encode_Type_Space = enum {
    raw,
    percent_encoded,
    @"+",
};
pub const Encode_Options = struct {
    unreserved: Encode_Type = .raw, // [-._~A-Za-z0-9]
    spaces: Encode_Type_Space = .@"+",
    reserved: struct {
        @"!": Encode_Type = .percent_encoded,
        @"#": Encode_Type = .percent_encoded,
        @"$": Encode_Type = .percent_encoded,
        @"&": Encode_Type = .percent_encoded,
        @"'": Encode_Type = .percent_encoded,
        @"(": Encode_Type = .percent_encoded,
        @")": Encode_Type = .percent_encoded,
        @"*": Encode_Type = .percent_encoded,
        @"+": Encode_Type = .percent_encoded,
        @",": Encode_Type = .percent_encoded,
        @"/": Encode_Type = .percent_encoded,
        @":": Encode_Type = .percent_encoded,
        @";": Encode_Type = .percent_encoded,
        @"=": Encode_Type = .percent_encoded,
        @"?": Encode_Type = .percent_encoded,
        @"@": Encode_Type = .percent_encoded,
        @"[": Encode_Type = .percent_encoded,
        @"]": Encode_Type = .percent_encoded,
    } = .{},
    other: Encode_Type = .percent_encoded,
};
pub fn encode_alloc(allocator: std.mem.Allocator, raw: []const u8, comptime options: Encode_Options) ![]const u8 {
    if (raw.len == 0) return allocator.dupe(u8, raw);

    var iter = encode(raw, options);
    const first = iter.next().?;
    if (first.len == raw.len and first.ptr == raw.ptr) return allocator.dupe(u8, raw);

    var len = first.len;
    while (iter.next()) |part| len += part.len;

    var result = std.ArrayListUnmanaged(u8).initBuffer(try allocator.alloc(u8, len));

    iter = encode(raw, options);
    while (iter.next()) |part| {
        result.appendSliceAssumeCapacity(part);
    }

    return result.items;
}
pub fn encode_maybe_append(list: *std.ArrayList(u8), raw: []const u8, comptime options: Encode_Options) ![]const u8 {
    // `raw` must not reference the list's backing buffer, since it might be reallocated in this function.
    std.debug.assert(@intFromPtr(raw.ptr) >= @intFromPtr(list.items.ptr + list.capacity)
                  or @intFromPtr(list.items.ptr) >= @intFromPtr(raw.ptr + raw.len));

    if (raw.len == 0) return raw;

    var iter = encode(raw, options);
    const first = iter.next().?;
    if (first.len == raw.len and first.ptr == raw.ptr) return first;

    const prefix_length = list.items.len;
    try list.appendSlice(first);
    while (iter.next()) |part| {
        try list.appendSlice(part);
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
    comptime if (options.spaces == .@"+") std.debug.assert(options.reserved.@"+" == .percent_encoded);
    return struct {
        remaining: []const u8,
        temp: [3]u8 = "%00".*,

        pub fn next(self: *@This()) ?[]const u8 {
            const remaining = self.remaining;
            if (remaining.len == 0) return null;

            for (0.., remaining) |i, c| {
                const should_encode = switch (c) {
                    'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => options.unreserved == .percent_encoded,
                    inline '!', '#', '$', '&', '\'', '(', ')', '*', '+', ',', '/', ':', ';', '=', '?', '@', '[', ']' => |cc| @field(options.reserved, &.{cc} ) == .percent_encoded,
                    ' ' => options.spaces != .raw,
                    else => options.other == .percent_encoded,
                };

                if (should_encode) {
                    if (i > 0) {
                        self.remaining = remaining[i..];
                        return remaining[0..i];
                    }
                    const temp: []u8 = &self.temp;
                    if (c == ' ' and options.spaces == .@"+") {
                        temp = temp[2..];
                        temp[0] = '+';
                    } else {
                        @memcpy(temp[1..], &std.fmt.bytesToHex(&[_]u8{c}, .upper));
                    }
                    self.remaining = remaining[1..];
                    return temp;
                }
            }

            self.remaining = "";
            return remaining;
        }
    };
}

pub const Decode_Options = struct {
    decode_plus_as_space: bool = true,
};
pub fn decode_alloc(allocator: std.mem.Allocator, encoded: []const u8, comptime options: Decode_Options) ![]const u8 {
    if (encoded.len == 0) return try allocator.dupe(u8, encoded);

    var iter = decode(encoded, options);
    const first = iter.next().?;
    if (first.len == encoded.len and first.ptr == encoded.ptr) return try allocator.dupe(u8, encoded);

    var len = first.len;
    while (iter.next()) |part| len += part.len;

    var result = std.ArrayListUnmanaged(u8).initBuffer(try allocator.alloc(u8, len));

    iter = decode(encoded, options);
    while (iter.next()) |part| {
        result.appendSliceAssumeCapacity(part);
    }

    return result.items;
}
pub fn decode_maybe_append(list: *std.ArrayList(u8), encoded: []const u8, comptime options: Decode_Options) ![]const u8 {
    // `encoded` must not reference the list's backing buffer, since it might be reallocated in this function.
    std.debug.assert(@intFromPtr(encoded.ptr) >= @intFromPtr(list.items.ptr + list.capacity)
                  or @intFromPtr(list.items.ptr) >= @intFromPtr(encoded.ptr + encoded.len));

    if (encoded.len == 0) return encoded;

    var iter = decode(encoded, options);
    const first = iter.next().?;
    if (first.len == encoded.len and first.ptr == encoded.ptr) return first;

    const prefix_length = list.items.len;
    try list.appendSlice(first);
    while (iter.next()) |part| {
        try list.appendSlice(part);
    }

    return list.items[prefix_length..];
}
pub fn decode_append(list: *std.ArrayList(u8), encoded: []const u8, comptime options: Decode_Options) !void {
    var iter = decode(encoded, options);
    while (iter.next()) |part| {
        try list.appendSlice(part);
    }
}
pub fn decode(encoded: []const u8, comptime options: Decode_Options) Decoder(options) {
    return .{ .remaining = encoded };
}
pub fn Decoder(comptime options: Decode_Options) type {
    return struct {
        remaining: []const u8,
        temp: [1]u8 = undefined,

        pub fn next(self: *@This()) ?[]const u8 {
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
            } else if (options.decode_plus_as_space and remaining[0] == '+') {
                self.temp[0] = ' ';
                self.remaining = remaining[1..];
                return &self.temp;
            }

            if (options.decode_plus_as_space) {
                if (std.mem.indexOfAny(u8, remaining, "%+")) |end| {
                    self.remaining = remaining[end..];
                    return remaining[0..end];
                }
            } else {
                if (std.mem.indexOfScalar(u8, remaining, '%')) |end| {
                    self.remaining = remaining[end..];
                    return remaining[0..end];
                }
            }

            self.remaining = "";
            return remaining;
        }
    };
}

pub fn fmtEncoded(raw: []const u8) std.fmt.Formatter(format) {
    return .{ .data = raw };
}

fn format(raw: []const u8, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
    comptime var encode_options: Encode_Options = .{};

    if (fmt.len > 0) {
        encode_options.reserved = .{
            .@"!" = .raw,
            .@"#" = .raw,
            .@"$" = .raw,
            .@"&" = .raw,
            .@"'" = .raw,
            .@"(" = .raw,
            .@")" = .raw,
            .@"*" = .raw,
            .@"+" = .raw,
            .@"," = .raw,
            .@"/" = .raw,
            .@":" = .raw,
            .@";" = .raw,
            .@"=" = .raw,
            .@"?" = .raw,
            .@"@" = .raw,
            .@"[" = .raw,
            .@"]" = .raw,
        };
        inline for (fmt) |c| switch (c) {
            '!' => encode_options.reserved.@"!" = .percent_encoded,
            '#' => encode_options.reserved.@"#" = .percent_encoded,
            '$' => encode_options.reserved.@"$" = .percent_encoded,
            '&' => encode_options.reserved.@"&" = .percent_encoded,
            '\'' => encode_options.reserved.@"'" = .percent_encoded,
            '(' => encode_options.reserved.@"(" = .percent_encoded,
            ')' => encode_options.reserved.@")" = .percent_encoded,
            '*' => encode_options.reserved.@"*" = .percent_encoded,
            '+' => encode_options.reserved.@"+" = .percent_encoded,
            ',' => encode_options.reserved.@"," = .percent_encoded,
            '/' => encode_options.reserved.@"/" = .percent_encoded,
            'c' => encode_options.reserved.@":" = .percent_encoded,
            ';' => encode_options.reserved.@";" = .percent_encoded,
            '=' => encode_options.reserved.@"=" = .percent_encoded,
            '?' => encode_options.reserved.@"?" = .percent_encoded,
            '@' => encode_options.reserved.@"@" = .percent_encoded,
            '[' => encode_options.reserved.@"[" = .percent_encoded,
            ']' => encode_options.reserved.@"]" = .percent_encoded,
            ' ' => encode_options.spaces = .percent_encoded,
            else => @compileError("invalid percent encoding format: " ++ fmt),
        };
        if (encode_options.reserved.@"+" == .raw) {
            encode_options.spaces = .percent_encoded;
        }
    }

    var encoder = encode(raw, encode_options);
    while (encoder.next()) |chunk| {
        try writer.writeAll(chunk);
    }
}

const std = @import("std");
