pub const Handler = *const fn(req: *Request) anyerror!void;
pub const Alloc_Handler = *const fn(allocator: std.mem.Allocator, req: *Request) anyerror!void;

pub fn router(server: anytype, comptime prefix: []const u8, comptime routes: anytype) !void {
    comptime var prefix_routes_list: []const []const u8 = &.{};
    comptime var exact_routes_list: []const struct { []const u8 } = &.{};

    const prefix_without_placeholder = if (comptime std.mem.endsWith(u8, prefix, "**")) prefix[0 .. prefix.len - 2] else prefix;

    inline for (routes) |route| {
        const path = route[0];
        if (route.len > 1) {
            inline for (1..route.len) |i| {
                try server.register(prefix_without_placeholder ++ path, route[i]);
            }
        }
        if (comptime std.mem.endsWith(u8, path, "**")) {
            prefix_routes_list = prefix_routes_list ++ .{ path };
        } else {
            exact_routes_list = exact_routes_list ++ .{ .{ path } };
        }
    }
    const exact_routes = std.ComptimeStringMap(void, exact_routes_list);

    const final_prefix_routes_list = prefix_routes_list[0..].*;

    try server.register(prefix, struct {
        pub fn route(allocator: std.mem.Allocator, req: *Request) anyerror!void {
            var path = req.unparsed_path;

            if (exact_routes.has(path)) {
                _ = try req.chain(try flow_name(allocator, path));
                req.unparsed_path = "";
                return;
            }

            for (final_prefix_routes_list) |prefix_path| {
                const prefix_path_without_suffix = prefix_path[0 .. prefix_path.len - 2];
                if (std.mem.startsWith(u8, path, prefix_path_without_suffix)) {
                    _ = try req.chain(try flow_name(allocator, prefix_path));
                    req.unparsed_path = path[prefix_path_without_suffix.len..];
                    return;
                }
            }

            path = try strip_path_params(allocator, path);

            if (exact_routes.has(path)) {
                _ = try req.chain(try flow_name(allocator, path));
                req.unparsed_path = "";
                return;
            }

            for (final_prefix_routes_list) |prefix_path| {
                const prefix_path_without_suffix = prefix_path[0 .. prefix_path.len - 2];
                if (std.mem.startsWith(u8, path, prefix_path_without_suffix)) {
                    _ = try req.chain(try flow_name(allocator, prefix_path));
                    req.unparsed_path = compute_new_unparsed_path(req, prefix_path);
                    return;
                }
            }
        }

        fn flow_name(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
            if (prefix_without_placeholder.len > 0) {
                return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix_without_placeholder, path });
            } else {
                return path;
            }
        }

        fn strip_path_params(allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
            const decoded = try percent_encoding.decode_alloc(allocator, target);

            var list = try std.ArrayList(u8).initCapacity(allocator, decoded.len);
            var iter = std.mem.splitScalar(u8, decoded, '/');
            var first = true;
            while (iter.next()) |part| {
                if (first) first = false else list.appendAssumeCapacity('/');

                if (std.mem.indexOfScalar(u8, part, ':')) |end| {
                    list.appendSliceAssumeCapacity(part[0 .. end + 1]);
                    list.appendAssumeCapacity('*');
                    continue;
                }

                _ = std.fmt.parseInt(u128, part, 10) catch {
                    list.appendSliceAssumeCapacity(part);
                    continue;
                };

                list.appendAssumeCapacity('*');
            }
            return std.mem.trimRight(u8, list.items, "/");
        }

        fn compute_new_unparsed_path(req: *Request, prefix_path_without_suffix: []const u8) []const u8 {
            var unparsed_iterator = req.unparsed_path_iterator();
            var prefix_iterator = std.mem.splitScalar(u8, prefix_path_without_suffix, '/');

            var chars_to_keep: usize = 0;
            var count_slash = false;
            while (unparsed_iterator.next()) |segment| {
                if (chars_to_keep == 0) {
                    if (prefix_iterator.next()) |prefix_segment| {
                        if (std.mem.endsWith(u8, prefix_segment, "*")) continue;

                        if (prefix_segment.len < segment.len) {
                            chars_to_keep += segment.len - prefix_segment.len;
                            count_slash = true;
                        }

                        continue;
                    }
                }

                if (count_slash) {
                    chars_to_keep += 1;
                } else {
                    count_slash = true;
                }
                chars_to_keep += segment.len;
            }

            const path = req.unparsed_path;
            return path[path.len - chars_to_keep .. path.len];
        }

    }.route);
}

pub fn generic(comptime source_path: []const u8) Alloc_Handler {
    const extension = comptime std.fs.path.extension(source_path);
    const source = resource_content(source_path);
    const content = comptime blk: {
        var buf: [source.len * 2]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        try template.render(source, {}, stream.writer(), resource_path_anyerror);
        break :blk stream.getWritten()[0..].*;
    };
    return static_internal(.{
        .content = &content,
        .content_type = content_type.lookup.get(extension),
        .cache_control = "must-revalidate, max-age=600, public",
        .last_modified_utc = root.resources.build_time,
    });
}

pub fn resource(comptime source_path: []const u8) struct { []const u8, Alloc_Handler } {
    const extension = std.fs.path.extension(source_path);
    return .{
        resource_path(source_path),
        static_internal(.{
            .content = resource_content(source_path),
            .content_type = content_type.lookup.get(extension),
            .cache_control = "max-age=31536000, immutable, public",
            .etag = resource_etag(source_path),
            .last_modified_utc = root.resources.build_time,
        }),
    };
}

pub fn resource_path_anyerror(comptime source_path: []const u8) anyerror![]const u8 {
    // TODO fix templater to allow the return type to have no error
    return resource_path(source_path);
}

pub fn resource_path(comptime source_path: []const u8) []const u8 {
    const extension = std.fs.path.extension(source_path);
    return comptime "/" ++ @field(root.resources, source_path) ++ extension;
}

pub fn resource_content(comptime source_path: []const u8) []const u8 {
    return @field(root.resources.content, source_path);
}

pub fn resource_etag(comptime source_path: []const u8) []const u8 {
    return @field(root.resources, source_path);
}

const Static_Internal_Route_Options = struct {
    content: []const u8,
    content_type: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    last_modified_utc: ?tempora.Date_Time = null,
    method: std.http.Method = .GET,
};
pub fn static_internal(comptime options: Static_Internal_Route_Options) Alloc_Handler {
    return struct {
        pub fn handler(allocator: std.mem.Allocator, req: *Request) anyerror!void {
            var content = options.content;
            switch (req.method) {
                options.method => {},
                .HEAD => content = "",
                else => return,
            }

            if (options.content_type) |ct| _ = try req.maybe_add_response_header("content-type", ct);
            if (options.cache_control) |cc| _ = try req.maybe_add_response_header("cache-control", cc);
            if (options.etag) |etag| _ = try req.maybe_add_response_header("etag", "\"" ++ etag ++ "\"");
            if (options.last_modified_utc) |dt| _ = try req.maybe_add_response_header("last-modified", try util.format_http_date(allocator, dt));

            var not_modified_by_date: ?bool = null;
            var not_modified_by_etag: ?bool = null;

            var iter = req.header_iterator();
            while (iter.next()) |header| {
                if (options.last_modified_utc) |last_modified| {
                    if (std.ascii.eqlIgnoreCase(header.name, "if-modified-since")) {
                        const DTO = tempora.Date_Time.With_Offset;
                        const last_seen = DTO.from_string(DTO.fmt_http, header.value) catch continue;
                        not_modified_by_date = !last_seen.dt.is_before(last_modified);
                    }
                }
                if (options.etag) |etag| {
                    if (std.ascii.eqlIgnoreCase(header.name, "if-none-match")) {
                        var inm_iter: ETag_Iterator = .{ .remaining = header.value };
                        not_modified_by_etag = while (try inm_iter.next()) |entry| {
                            if (std.mem.eql(u8, entry.value, etag)) {
                                break true;
                            }
                        } else false;
                    }
                }
            }

            const allow_cache = if (req.get_response_header("cache-control")) |header| !std.mem.eql(u8, header, "no-cache") else true;

            if (allow_cache and (not_modified_by_etag orelse not_modified_by_date orelse false)) {
                req.response_status = .not_modified;
                content = "";
            }

            try req.respond(content);
        }
    }.handler;
}

pub fn module(comptime Injector: type, comptime Module: type) Handler {
    return struct {
        pub fn handler(req: *Request) anyerror!void {
            switch (req.method) {
                .GET => if (@hasDecl(Module, "get")) return try Injector.call(Module.get, {}),
                .HEAD => if (@hasDecl(Module, "head")) return try Injector.call(Module.head, {}),
                .POST => if (@hasDecl(Module, "post")) return try Injector.call(Module.post, {}),
                .PUT => if (@hasDecl(Module, "put")) return try Injector.call(Module.put, {}),
                .DELETE => if (@hasDecl(Module, "delete")) return try Injector.call(Module.delete, {}),
                .CONNECT => if (@hasDecl(Module, "connect")) return try Injector.call(Module.connect, {}),
                .OPTIONS => if (@hasDecl(Module, "options")) return try Injector.call(Module.options, {}),
                .TRACE => if (@hasDecl(Module, "trace")) return try Injector.call(Module.trace, {}),
                .PATCH => if (@hasDecl(Module, "patch")) return try Injector.call(Module.patch, {}),
                _ => {},
            }

            try req.respond_err(.{ .status = .method_not_allowed });
            return error.SkipRemainingHandlers;
        }
    }.handler;
}

pub fn method(comptime required_method: std.http.Method) Handler {
    return struct {
        pub fn handler(req: *Request) anyerror!void {
            if (req.method != required_method) {
                try req.respond_err(.{ .status = .method_not_allowed });
                return error.SkipRemainingHandlers;
            }
        }
    }.handler;
}

pub fn shutdown(req: *Request, pool: *Pool) !void {
    log.info("starting shutdown", .{});
    try req.set_response_header("cache-control", "no-cache");
    req.response_keep_alive = false;
    pool.stop();
}

const log = std.log.scoped(.http);

const template = @import("template.zig");
const util = @import("util.zig");
const content_type = @import("content_type.zig");
const percent_encoding = @import("percent_encoding.zig");
const ETag_Iterator = @import("ETag_Iterator.zig");
const Request = @import("Request.zig");
const Pool = @import("Pool.zig");
const tempora = @import("tempora");
const std = @import("std");
const root = @import("root");
