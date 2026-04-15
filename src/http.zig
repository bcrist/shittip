pub const Loop = @import("Loop.zig");

pub const Server = server.Server;
pub const Default_Server = @import("default_server.zig").Default_Server;
pub fn default_server(loop: *Loop, comptime comptime_options: server.Comptime_Options) Default_Server(comptime_options) {
    return .init(loop);
}
pub const Server_Tasks = @import("Server_Tasks.zig");
pub const Connection_Id = @import("Connection_Id.zig");
pub const Index_Pool = @import("Index_Pool.zig");
pub const routing = @import("routing.zig");
pub const Request = @import("Request.zig");

pub const Charset = @import("charset.zig").Charset;
pub const Content_Type = @import("content_type.zig").Content_Type;
pub const Content_Disposition = @import("content_disposition.zig").Content_Disposition;

pub const percent_encoding = @import("percent_encoding");

pub const ETag_Iterator = @import("ETag_Iterator.zig");
pub fn etag_iterator(raw_value: []const u8) ETag_Iterator {
    return .{ .remaining = raw_value };
}

pub const Query_Iterator = @import("Query_Iterator.zig");
pub fn query_iterator(allocator: std.mem.Allocator, raw_value: []const u8) Query_Iterator {
    return Query_Iterator.init(allocator, raw_value);
}

pub const Query_Reader = @import("Query_Reader.zig");
pub fn query_reader(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Query_Reader {
    return Query_Reader.init(allocator, reader);
}

const tempora = @import("tempora");
const server = @import("server.zig");
const std = @import("std");
