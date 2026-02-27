pub const Charset = union (enum) {
    ascii,
    utf8,
    iso_8859_1,
    other: []const u8,

    pub fn format(self: Charset, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.to_string());
    }

    pub fn to_string(self: Charset) []const u8 {
        return switch (self) {
            .ascii => "US-ASCII",
            .utf8 => "UTF-8",
            .iso_8859_1 => "ISO-8859-1",
            .other => |raw| raw,
        };
    }

    pub fn parse(str: []const u8) Charset {
        if (std.ascii.eqlIgnoreCase(str, "utf-8")) return .utf8;
        if (std.ascii.eqlIgnoreCase(str, "utf8")) return .utf8;
        if (std.ascii.eqlIgnoreCase(str, "utf_8")) return .utf8;
        if (std.ascii.eqlIgnoreCase(str, "iso-8859-1")) return .iso_8859_1;
        if (std.ascii.eqlIgnoreCase(str, "us-ascii")) return .ascii;
        if (std.ascii.eqlIgnoreCase(str, "ascii")) return .ascii;
        if (str.len == 0) return .ascii;
        return .{ .other = str };
    }
};

const std = @import("std");
