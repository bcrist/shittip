pub fn format_http_date(allocator: std.mem.Allocator, utc: tempora.Date_Time) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{" ++ tempora.Date_Time.With_Offset.fmt_http ++ "}", .{ utc.with_offset(0) });
}

pub fn parse_hostname(temp: std.mem.Allocator, hostname: []const u8, port: u16) !std.net.Address {
    const list = try std.net.getAddressList(temp, hostname, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;

    for (list.addrs) |addr| {
        if (addr.any.family == std.os.AF.INET) return addr;
    }
    
    return list.addrs[0];
}

pub const Default_Injector = dizzy.Injector(struct {

    pub fn inject_allocator() std.mem.Allocator {
        return server.temp.allocator();
    }

    pub fn inject_request() *Request {
        return &server.request;
    }

    pub fn inject_response() !*std.http.Server.Response {
        return server.request.response();
    }

    pub fn inject_maybe_response() ?*std.http.Server.Response {
        var req = &server.request;
        switch (req.response_state) {
            .streaming => |*resp| return resp,
            else => return null,
        }
    }

    pub fn inject_pool() *Pool {
        return server.thread_pool;
    }

    pub fn inject_registry() *const server.Registry {
        return server.registry;
    }

}, .{});


const Pool = @import("Pool.zig");
const Request = @import("Request.zig");
const server = @import("server.zig");
const dizzy = @import("dizzy");
const tempora = @import("tempora");
const std = @import("std");
