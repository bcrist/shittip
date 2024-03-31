pub fn main() !void {
    defer std.debug.assert(gpa.deinit() == .ok);

    var server = http.Server(http.Default_Injector).init(gpa.allocator());
    defer server.deinit();

    const r = http.routing;
    try server.router("", .{
        .{ "/", r.generic("index.html") },
        .{ "/**" },
        r.resource("style.css"),
    });

    try server.router("/**", .{
        .{ "shutdown", r.method(.GET), r.shutdown, r.generic("shutdown.html") },
    });

    const addr = try http.parse_hostname(gpa.allocator(), "localhost", 21345);
    try server.start(.{ .address = addr });
    try server.run();
}

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

pub const resources = @import("resources");

const http = @import("http");
const std = @import("std");
