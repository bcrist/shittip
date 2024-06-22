pub fn main() !void {
    defer std.debug.assert(gpa.deinit() == .ok);

    const Injector = http.Default_Injector;
    var server = http.Server(Injector).init(gpa.allocator());
    defer server.deinit();

    const r = http.routing;
    try server.router("", .{
        .{ "/", r.module(Injector, index) },
        .{ "/something/**" },
        .{ "/something_else/**", "/something/**" },
        r.resource("style.css"),
    });

    try server.router("/something/**", .{
        .{ "shutdown", r.method(.GET), r.shutdown },
        .{ "hello", r.module(Injector, hello) },
        .{ "hello/id:*", r.module(Injector, hello) },
    });

    const addr = try http.parse_hostname(gpa.allocator(), "localhost", 21345);
    try server.start(.{ .address = addr });
    try server.run();
}

const hello = struct {
    pub fn get(req: *http.Request) !void {
        std.log.info("Hellorld!", .{});
        try req.respond("Hellorld!");
    }

    pub fn post(req: *http.Request) !void {
        std.log.info("Hello Post!", .{});
        try req.respond("Hello Post!");
    }
};

const index = struct {
    pub fn get(req: *http.Request) !void {
        try req.render("index.zk", {}, .{});
    }
};

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

pub const resources = @import("resources");

const http = @import("http");
const std = @import("std");
