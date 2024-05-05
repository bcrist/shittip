

fn run_server_guarded() void {
    run_server() catch @panic("run_server() errored!");
}

fn run_server() !void {
    var server = http.Server(http.Default_Injector).init(std.testing.allocator);
    defer server.deinit();

    const r = http.routing;
    try server.router("", .{
        .{ "/hello",
            r.static_internal(.{
                .content = "Hello World",
                .content_type = http.content_type.text,
            }),
        },
        .{ "/shutdown",
            r.shutdown,
            r.static_internal(.{
                .content = "Shutting Down",
                .content_type = http.content_type.html,
            }),
        },
    });

    const addr = try http.parse_hostname(std.testing.allocator, "127.0.0.1", 21345);
    try server.start(.{ .address = addr, .connection_threads = 0 });
    try server.run();
}


test "server lifecycle" {
    var server_thread = try std.Thread.spawn(.{}, run_server, .{});
    defer server_thread.join();

    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();

    var buf: [8192]u8 = undefined;

    {
        var req = try client.open(.GET, try std.Uri.parse("http://localhost:21345/hello"), .{
            .server_header_buffer = &buf,
            .keep_alive = false,
        });
        defer req.deinit();
        try req.send();
        try req.wait();
        const content = try req.reader().readAllAlloc(std.testing.allocator, 10000);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("Hello World", content);
    }
    {
        var req = try client.open(.GET, try std.Uri.parse("http://localhost:21345/shutdown"), .{
            .server_header_buffer = &buf,
            .keep_alive = false,
        });
        defer req.deinit();
        try req.send();
        try req.wait();
    }
}

const http = @import("http");
const std = @import("std");
