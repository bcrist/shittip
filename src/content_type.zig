pub const without_encoding = struct {
    pub const text = "text/plain";
    pub const html = "text/html";
    pub const css = "text/css";
    pub const js = "text/javascript";
    pub const json = "application/json";
    pub const xml = "application/xml";
    pub const form_urlencoded = "application/x-www-form-urlencoded";
};

pub const text = without_encoding.text ++ "; charset=UTF-8";
pub const html = without_encoding.html ++ "; charset=UTF-8";
pub const css = without_encoding.css ++ "; charset=UTF-8";
pub const js = without_encoding.js ++ "; charset=UTF-8";
pub const json = without_encoding.json ++ "; charset=UTF-8";
pub const xml = without_encoding.xml ++ "; charset=UTF-8";
pub const form_urlencoded = without_encoding.form_urlencoded ++ "; charset=UTF-8";

pub const jpeg = "image/jpeg";
pub const png = "image/png";
pub const gif = "image/gif";
pub const svg = "image/svg+xml; charset=UTF-8";
pub const icon = "image/x-icon";
pub const pdf = "application/pdf";
pub const ttf = "font/ttf";
pub const woff2 = "font/woff2";

pub const lookup = util.ComptimeStringMap([]const u8, .{
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

const util = @import("util.zig");
const std = @import("std");
