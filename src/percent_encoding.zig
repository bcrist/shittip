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
pub fn encode(raw: []const u8, comptime options: Encode_Options) Encoder(options) {
    return .{ .remaining = raw };
}
pub fn Encoder(comptime options: Encode_Options) type {
    return struct {
        remaining: []const u8,
        temp: [3]u8 = "%00",

        pub fn next(self: *Encoder) ?[]const u8 {
            const remaining = self.remaining;
            if (remaining.len == 0) return null;

            for (0.., remaining) |i, c| {
                const should_encode = switch (c) {
                    'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => options == .encode_all,
                    inline '!', '#', '$', '&', '\'', '(', ')', '*', '+', ',', '/', ':', ';', '=', '?', '@', '[', ']' => |cc|
                        switch (options) {
                            .encode_all, .encode_other_and_reserved => true,
                            .encode_other => false,
                            .encode_other_and => |char_flags| @field(char_flags, cc),
                        },
                    else => true,
                };

                if (should_encode) {
                    if (i > 0) {
                        self.remaining = remaining[i..];
                        return remaining[0..i];
                    }
                    const temp: []const u8 = self.temp;
                    @memcpy(temp[1..], std.fmt.bytesToHex(&[_]u8{c}, .upper));
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

const std = @import("std");
