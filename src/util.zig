pub inline fn maybe_string(ptr: anytype) ?[]const u8 {
    switch (@typeInfo(@TypeOf(ptr.*))) {
        .pointer => |info| {
            if (info.child == u8 and info.size == .slice) {
                return ptr.*;
            }
            if (info.size == .one) {
                switch (@typeInfo(info.child)) {
                    .array => |array_info| {
                        if (array_info.child == u8) {
                            return ptr.*;
                        }
                    },
                    else => {},
                }
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                return ptr;
            }
        },
        else => {},
    }
    return null;
}

pub fn format_http_date(allocator: std.mem.Allocator, utc: tempora.Date_Time) ![]const u8 {
    return std.fmt.allocPrint(allocator, tempora.Date_Time.With_Offset.http, .{ utc.with_offset(0) });
}

pub fn parse_hostname(temp: std.mem.Allocator, hostname: []const u8, port: u16) !std.net.Address {
    const list = try std.net.getAddressList(temp, hostname, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;

    for (list.addrs) |addr| {
        if (addr.any.family == std.posix.AF.INET) return addr;
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

    pub fn inject_pools() server.Pools {
        return server.pools;
    }

    pub fn inject_registry() *const server.Registry {
        return server.registry;
    }

}, .{});

pub const ComptimeStringMap = if (@import("builtin").zig_version.minor == 12)
    std.ComptimeStringMap // TODO remove zig 0.12 support when zig 0.14 is released
else struct {
    pub fn ComptimeStringMap(comptime T: type, comptime kvs: anytype) std.StaticStringMap(T) {
        return std.StaticStringMap(T).initComptime(kvs);
    }
}.ComptimeStringMap;

const Pool = @import("Pool.zig");
const Request = @import("Request.zig");
const server = @import("server.zig");
const dizzy = @import("dizzy");
const tempora = @import("tempora");
const std = @import("std");
