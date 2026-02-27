pub const Content_Type = union (enum) {
    text: ?Charset,
    html: ?Charset,
    css: ?Charset,
    javascript: ?Charset,
    csv: ?Charset,
    json: ?Charset,
    xml: ?Charset,
    binary,
    pdf,
    zip,
    form_urlencoded: ?Charset,
    form_multipart: []const u8,
    svg: ?Charset,
    jpeg,
    png,
    gif,
    icon,
    ttf,
    otf,
    woff2,
    mp3,
    vorbis,
    other: struct {
        @"type": []const u8,
        subtype: []const u8,
        param: ?Param,
    },

    pub const text_utf8: Content_Type = .{ .text = .utf8 };
    pub const html_utf8: Content_Type = .{ .html = .utf8 };
    pub const css_utf8: Content_Type = .{ .css = .utf8 };
    pub const javascript_utf8: Content_Type = .{ .javascript = .utf8 };
    pub const csv_utf8: Content_Type = .{ .csv = .utf8 };
    pub const json_utf8: Content_Type = .{ .json = .utf8 };
    pub const xml_utf8: Content_Type = .{ .xml = .utf8 };
    pub const svg_utf8: Content_Type = .{ .svg = .utf8 };
    pub const form_urlencoded_utf8: Content_Type = .{ .form_urlencoded = .utf8 };

    pub fn @"type"(self: Content_Type) []const u8 {
        return switch (self) {
            .text, .html, .css, .javascript, .csv => "text",
            .json, .xml, .form_urlencoded, .binary, .pdf, .zip => "application",
            .form_multipart => "multipart",
            .svg, .jpeg, .png, .gif, .icon => "image",
            .ttf, .otf, .woff2 => "font",
            .mp3, .vorbis => "audio",
            .other => |info| info.@"type",
        };
    }

    pub fn subtype(self: Content_Type) []const u8 {
        return switch (self) {
            .text => "plain",
            .form_urlencoded => "x-www-form-urlencoded",
            .binary => "octet-stream",
            .form_multipart => "form-data",
            .svg => "svg+xml",
            .icon => "x-icon",
            .mp3 => "mpeg",
            .other => |info| info.subtype,
            inline else => |_, ct| @tagName(ct),
        };
    }

    pub const Param = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn param(self: Content_Type) ?Param {
        return switch (self) {
            .text, .html, .css, .javascript, .csv, .json, .xml, .form_urlencoded, .svg => |maybe_cs| {
                return if (maybe_cs) |cs| .{
                    .name = "charset",
                    .value = cs.to_string(),
                } else null;
            },
            .form_multipart => |boundary| .{
                .name = "boundary",
                .value = boundary
            },
            .binary, .pdf, .zip, .jpeg, .png, .gif, .icon, .ttf, .otf, .woff2, .mp3, .vorbis => null,
            .other => |info| info.param,
        };
    }

    pub fn format(self: Content_Type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.@"type"());
        try writer.writeByte('/');
        try writer.writeAll(self.subtype());
        if (self.param()) |p| {
            try writer.writeAll("; ");
            try writer.writeAll(p.name);
            try writer.writeByte('=');
            try writer.writeAll(p.value);
        }
    }

    pub fn to_string(comptime self: Content_Type) []const u8 {
        return comptime std.fmt.comptimePrint("{f}", .{ self });
    }

    pub fn parse(str: []const u8) Content_Type {
        const initial_part = if (std.mem.indexOfScalar(u8, str, ';')) |end| str[0..end] else str;
        const param_part = if (initial_part.len < str.len) str[initial_part.len + 1 ..] else "";

        const name_part = if (std.mem.indexOfScalar(u8, param_part, '=')) |end| param_part[0..end] else param_part;
        const value_part = if (name_part.len < param_part.len) param_part[name_part.len + 1 ..] else "";

        const name_trimmed = std.mem.trim(u8, name_part, " ");
        const value_trimmed = std.mem.trim(u8, value_part, " ");

        if (mime_lookup.get(initial_part)) |static_mime| {
            var mime = static_mime;
            switch (mime) {
                .text, .html, .css, .javascript, .csv, .json, .xml, .form_urlencoded, .svg => |*maybe_cs| {
                    if (std.ascii.eqlIgnoreCase(name_trimmed, "charset")) {
                        maybe_cs.* = Charset.parse(value_trimmed);
                        return mime;
                    } else if (name_trimmed.len == 0 and value_trimmed.len == 0) {
                        maybe_cs.* = null;
                        return mime;
                    }
                },
                .form_multipart => |*boundary| {
                    if (std.ascii.eqlIgnoreCase(name_trimmed, "boundary")) {
                        boundary.* = value_trimmed;
                        return mime;
                    }
                },
                .binary, .pdf, .zip, .jpeg, .png, .gif, .icon, .ttf, .otf, .woff2, .mp3, .vorbis => {
                    if (name_trimmed.len == 0 and value_trimmed.len == 0) return mime;
                },
                .other => unreachable,
            }
        }

        const type_part = if (std.mem.indexOfScalar(u8, initial_part, '/')) |end| initial_part[0..end] else initial_part;
        const subtype_part = if (type_part.len < initial_part.len) initial_part[type_part.len + 1 ..] else "";
        
        return .{ .other = .{
            .@"type" = type_part,
            .subtype = subtype_part,
            .param = if (name_trimmed.len > 0 or value_trimmed.len > 0) .{
                .name = name_trimmed,
                .value = value_trimmed,
            } else null,
        }};
    }

    const mime_lookup = std.StaticStringMapWithEql(Content_Type, std.ascii.eqlIgnoreCase).initComptime(.{
        .{ "text/plain", Content_Type.text_utf8 },
        .{ "text/html", Content_Type.html_utf8 },
        .{ "text/css", Content_Type.css_utf8 },
        .{ "text/csv", Content_Type.csv_utf8 },
        .{ "text/javascript", Content_Type.javascript_utf8 },
        .{ "text/ecmascript", Content_Type.javascript_utf8 },
        .{ "text/x-javascript", Content_Type.javascript_utf8 },
        .{ "text/x-ecmascript", Content_Type.javascript_utf8 },
        .{ "application/javascript", Content_Type.javascript_utf8 },
        .{ "application/ecmascript", Content_Type.javascript_utf8 },
        .{ "application/x-javascript", Content_Type.javascript_utf8 },
        .{ "application/x-ecmascript", Content_Type.javascript_utf8 },
        .{ "application/json", Content_Type.json_utf8 },
        .{ "text/json", Content_Type.json_utf8 },
        .{ "application/xml", Content_Type.xml_utf8 },
        .{ "text/xml", Content_Type.xml_utf8 },
        .{ "image/svg+xml", Content_Type.svg_utf8 },
        .{ "text/svg+xml", Content_Type.svg_utf8 },
        .{ "application/svg+xml", Content_Type.svg_utf8 },
        .{ "image/svg", Content_Type.svg_utf8 },
        .{ "text/svg", Content_Type.svg_utf8 },
        .{ "image/jpeg", Content_Type.jpeg },
        .{ "image/png", Content_Type.png },
        .{ "image/gif", Content_Type.gif },
        .{ "image/x-icon", Content_Type.icon },
        .{ "image/vnd.microsoft.icon", Content_Type.icon },
        .{ "application/pdf", Content_Type.pdf },
        .{ "application/zip", Content_Type.zip },
        .{ "application/octet-stream", Content_Type.binary },
        .{ "font/ttf", Content_Type.ttf },
        .{ "font/otf", Content_Type.otf },
        .{ "font/woff2", Content_Type.woff2 },
        .{ "audio/mpeg", Content_Type.mp3 },
        .{ "audio/vorbis", Content_Type.vorbis },
        .{ "multipart/form-data", Content_Type { .form_multipart = "" } },
        .{ "application/x-www-form-urlencoded", Content_Type.form_urlencoded_utf8 },
    });

    pub const ext_lookup = std.StaticStringMapWithEql(Content_Type, std.ascii.eqlIgnoreCase).initComptime(.{
        .{ ".txt", Content_Type.text_utf8 },
        .{ ".htm", Content_Type.html_utf8 },
        .{ ".html", Content_Type.html_utf8 },
        .{ ".zk", Content_Type.html_utf8 },
        .{ ".css", Content_Type.css_utf8 },
        .{ ".js", Content_Type.javascript_utf8 },
        .{ ".json", Content_Type.json_utf8 },
        .{ ".xml",  Content_Type.xml_utf8 },
        .{ ".csv", Content_Type.csv_utf8 },
        .{ ".jpg", Content_Type.jpeg },
        .{ ".png", Content_Type.png },
        .{ ".gif", Content_Type.gif },
        .{ ".svg", Content_Type.svg_utf8 },
        .{ ".ico", Content_Type.icon },
        .{ ".pdf", Content_Type.pdf },
        .{ ".zip", Content_Type.zip },
        .{ ".ttf", Content_Type.ttf },
        .{ ".otf", Content_Type.otf },
        .{ ".woff2", Content_Type.woff2 },
        .{ ".mp3", Content_Type.mp3 },
        .{ ".ogg", Content_Type.vorbis },
        .{ ".vorbis", Content_Type.vorbis },
    });
};

const Charset = @import("charset.zig").Charset;
const std = @import("std");
