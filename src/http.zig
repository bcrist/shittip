pub const Server = server.Server;
pub const Default_Injector = util.Default_Injector; 
pub const parse_hostname = util.parse_hostname;
pub const routing = @import("routing.zig");
pub const template = @import("template.zig");
pub const Request = @import("Request.zig");
pub const content_type = @import("content_type.zig");
pub const percent_encoding = @import("percent_encoding.zig");
pub const format_http_date = util.format_http_date;

pub const ETag_Iterator = @import("ETag_Iterator.zig");
pub fn etag_iterator(raw_value: []const u8) ETag_Iterator {
    return .{ .remaining = raw_value };
}

pub const Query_Iterator = @import("Query_Iterator.zig");
pub fn query_iterator(allocator: std.mem.Allocator, raw_value: []const u8) Query_Iterator {
    return Query_Iterator.init(allocator, raw_value);
}

pub fn temp() std.mem.Allocator {
    return server.temp.allocator();
}

pub const Thread_Pool = @import("Pool.zig");
const util = @import("util.zig");
const server = @import("server.zig");
const std = @import("std");
