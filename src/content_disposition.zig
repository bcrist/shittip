pub const Content_Disposition = union (enum) {
    @"inline",
    attachment,
    attachment_filename: []const u8,
    attachment_filename_utf8: []const u8,
    attachment_filename_iso8859: []const u8,
    form_data: []const u8,
    form_data_filename: struct {
        name: []const u8,
        filename: []const u8,
    },

    pub fn format(self: Content_Disposition, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .@"inline", .attachment => try writer.writeAll(@tagName(self)),
            .attachment_filename => |filename| {
                try writer.print("attachment; filename=\"{f}\"", .{
                    percent_encoding.fmt(filename, .init(.none, .{ .percent_encoded = "\"Z" })),
                });
            },
            .attachment_filename_utf8 => |filename| {
                try writer.print("attachment; filename=\"{f}\"; filename*=UTF-8''{f}", .{
                    percent_encoding.fmt(filename, .init(.none, .{ .percent_encoded = "\"Z" })),
                    percent_encoding.fmt(filename, .default),
                });
            },
            .attachment_filename_iso8859 => |filename| {
                try writer.print("attachment; filename=\"{f}\"; filename*=ISO-8859-1''{f}", .{
                    percent_encoding.fmt(filename, .init(.none, .{ .percent_encoded = "\"Z" })),
                    percent_encoding.fmt(filename, .default),
                });
            },
            .form_data => |name| {
                try writer.print("form-data; name=\"{f}\"", .{
                    percent_encoding.fmt(name, .init(.none, .{ .percent_encoded = "\"Z" })),
                });
            },
            .form_data_filename => |info| {
                try writer.print("form-data; name=\"{f}\"; filename=\"{f}\"", .{
                    percent_encoding.fmt(info.name, .init(.none, .{ .percent_encoded = "\"Z" })),
                    percent_encoding.fmt(info.filename, .init(.none, .{ .percent_encoded = "\"Z" })),
                });
            },
        }
    }

    pub fn to_string(comptime self: Content_Disposition) []const u8 {
        return comptime std.fmt.comptimePrint("{f}", .{ self });
    }
};

const percent_encoding = @import("percent_encoding");
const std = @import("std");
