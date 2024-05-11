pub const text = "text/plain; charset=UTF-8";
pub const html = "text/html; charset=UTF-8";
pub const css = "text/css; charset=UTF-8";
pub const js = "text/javascript; charset=UTF-8";
pub const json = "application/json; charset=UTF-8";
pub const xml = "application/xml; charset=UTF-8";

pub const jpeg = "image/jpeg";
pub const png = "image/png";
pub const gif = "image/gif";
pub const svg = "image/svg+xml; charset=UTF-8";
pub const icon = "image/x-icon";
pub const pdf = "application/pdf";
pub const ttf = "font/ttf";
pub const woff2 = "font/woff2";

pub const lookup = std.ComptimeStringMap([]const u8, .{
    .{ ".txt", text },
    .{ ".htm", html },
    .{ ".html", html },
    .{ ".zk", html },
    .{ ".css", css },
    .{ ".js", js },
    .{ ".json", json },
    .{ ".xml",  xml },
    .{ ".jpg", jpeg },
    .{ ".png", png },
    .{ ".gif", gif },
    .{ ".svg", svg },
    .{ ".ico", icon },
    .{ ".pdf", pdf },
    .{ ".ttf", ttf },
    .{ ".woff2", woff2 },
});

const std = @import("std");
