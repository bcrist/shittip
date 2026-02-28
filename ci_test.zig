test "server lifecycle" {
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
    try server.stop();
}

const http = @import("http");
const std = @import("std");
