connection_number: usize,
req: std.http.Server.Request,
method: std.http.Method = @enumFromInt(0),
full_path: []const u8 = "",
unparsed_path: []const u8 = "",
query: []const u8 = "",
hash: []const u8 = "",
received_dt: tempora.Date_Time,
handlers: Handler_Fifo,
response_headers: std.ArrayList(std.http.Header),
response_version: ?std.http.Version = null,
response_status: std.http.Status = .ok,
response_reason: ?[]const u8 = null,
response_keep_alive: bool = true,
response_transfer_encoding: ?std.http.TransferEncoding = null,
response_content_length: ?u64 = null,
response_state: union (enum) {
    not_started,
    streaming: std.http.Server.Response,
    sent,
} = .not_started,

const Request = @This();
pub const Handler_Fifo = std.fifo.LinearFifo(Handler_Func, .Dynamic);
pub const Handler_Func = *const fn () anyerror!void;

pub fn handle(self: *Request) error{CloseConnection}!void {
    self.method = self.req.head.method;
    self.full_path = if (std.mem.indexOfAny(u8, self.req.head.target, "?#")) |end| self.req.head.target[0..end] else self.req.head.target;
    self.unparsed_path = self.full_path;
    
    const remaining_target = self.req.head.target[self.full_path.len..];
    self.query = if (std.mem.indexOfScalar(u8, remaining_target, '#')) |end| remaining_target[0..end] else remaining_target;
    self.hash = remaining_target[self.query.len..];

    log.debug("C{}: {s} {s}", .{
        self.connection_number,
        @tagName(self.method),
        self.req.head.target,
    });

    self.try_set_date() catch {};

    self.handlers = Handler_Fifo.init(server.temp.allocator());
    _ = try self.chain("");

    while (self.handlers.readItem()) |handler| {
        handler() catch |err| switch (err) {
            error.CloseConnection => return error.CloseConnection,
            error.SkipRemainingHandlers => break,
            error.BadRequest => try self.maybe_respond_err(.{ .status = .bad_request }),
            else => try self.maybe_respond_err(.{ .err = err, .trace = @errorReturnTrace() }),
        };
    }

    switch (self.response_state) {
        .not_started => try self.maybe_respond_err(.{ .status = .not_found }),
        .streaming => |*res| res.end() catch |err| {
            log.err("C{}: Failed to flush response stream: {}", .{ self.connection_number, err });
            return error.CloseConnection;
        },
        .sent => {},
    }
}

fn try_set_date(self: *Request) !void {
    try self.set_response_header("date", try util.format_http_date(server.temp.allocator(), self.received_dt));
}

pub fn chain(self: *Request, flow: []const u8) error{CloseConnection}!bool {
    if (server.registry.get(flow)) |handlers| {
        log.debug("C{}: Chaining {} handler(s) for flow '{}'", .{
            self.connection_number,
            handlers.items.len,
            std.zig.fmtEscapes(flow),
        });
        self.handlers.write(handlers.items) catch |err| {
            log.err("C{}: Failed to allocate handlers list: {}", .{ self.connection_number, err });
            try self.maybe_respond_err(.{ .err = err, .status = .internal_server_error });
            return error.CloseConnection;
        };
        return true;
    } else {
        log.debug("C{}: No handler(s) for flow '{}'", .{
            self.connection_number,
            std.zig.fmtEscapes(flow),
        });
    }
    return false;
}

pub fn header_iterator(self: *Request) std.http.HeaderIterator {
    return self.req.iterateHeaders();
}

pub fn path_iterator(self: *Request) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, self.full_path, '/');
}

pub fn unparsed_path_iterator(self: *Request) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, self.unparsed_path, '/');
}

pub fn ensure_response_not_started(self: *Request) !void {
    if (self.response_state != .not_started) return error.ResponseAlreadyStarted;
}

pub fn add_response_header(self: *Request, name: []const u8, value: []const u8) !void {
    try self.ensure_response_not_started();
    try self.response_headers.append(.{
        .name = name,
        .value = value,
    });
}

pub fn maybe_add_response_header(self: *Request, name: []const u8, value: []const u8) !bool {
    try self.ensure_response_not_started();

    for (self.response_headers.items) |*header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return false;
        }
    }
    
    try self.response_headers.append(.{
        .name = name,
        .value = value,
    });
    return true;
}

pub fn set_response_header(self: *Request, name: []const u8, value: []const u8) !void {
    try self.ensure_response_not_started();

    for (self.response_headers.items) |*header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            header.value = value;
            return;
        }
    }

    try self.response_headers.append(.{
        .name = name,
        .value = value,
    });
}

pub fn get_response_header(self: *Request, name: []const u8) ?[]const u8 {
    for (self.response_headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return header.value;
        }
    }
    return null;
}

pub fn response(self: *Request) !*std.http.Server.Response {
    switch (self.response_state) {
        .not_started => {
            log.info("C{}: [{}] {s} {s}", .{
                self.connection_number,
                @intFromEnum(self.response_status),
                @tagName(self.method),
                self.req.head.target,
            });

            const send_buf = try server.temp.allocator().alloc(u8, 65536);

            self.response_state = .{
                .streaming = self.req.respondStreaming(.{
                    .send_buffer = send_buf,
                    .content_length = self.response_content_length,
                    .respond_options = self.respond_options(),
                }),
            };
            return &self.response_state.streaming;
        },
        .streaming => |*resp| return resp,
        .sent => return error.ResponseAlreadySent,
    }
}

pub fn respond(self: *Request, content: []const u8) !void {
    try self.ensure_response_not_started();
    self.response_state = .sent;

    log.info("C{}: [{}] {s} {s}", .{
        self.connection_number,
        @intFromEnum(self.response_status),
        @tagName(self.method),
        self.req.head.target,
    });

    self.response_content_length = content.len;

    try self.req.respond(content, self.respond_options());
}

fn respond_options(self: *Request) std.http.Server.Request.RespondOptions {
    return .{
        .version = self.response_version orelse self.req.head.version,
        .status = self.response_status,
        .reason = self.response_reason,
        .keep_alive = self.response_keep_alive,
        .extra_headers = self.response_headers.items,
        .transfer_encoding = self.response_transfer_encoding,
    };
}

const Respond_Err_Options = struct {
    empty_content: bool = false,
    status: std.http.Status = .internal_server_error,
    err: ?anyerror = null,
    trace: ?*std.builtin.StackTrace = null,
};
pub fn respond_err(self: *Request, options: Respond_Err_Options) !void {
    try self.ensure_response_not_started();

    if (!options.empty_content) {
        try self.set_response_header("content-type", content_type.html);
    }

    self.response_state = .sent;

    if (options.err) |e| {
        log.info("C{}: [{} {}] {s} {s}", .{
            self.connection_number,
            @intFromEnum(options.status),
            e,
            @tagName(self.method),
            self.req.head.target,
        });
    } else {
        log.info("C{}: [{}] {s} {s}", .{
            self.connection_number,
            @intFromEnum(options.status),
            @tagName(self.method),
            self.req.head.target,
        });
    }
    if (options.trace) |ert| {
        std.debug.dumpStackTrace(ert.*);
    }

    const content = format_err_response(options) catch |err| {
        log.warn("C{}: Closing connection (failed to format error response: {})", .{ self.connection_number, err });
        if (@errorReturnTrace()) |ert| std.debug.dumpStackTrace(ert.*);
        return error.CloseConnection;
    };

    self.response_status = options.status;
    self.response_content_length = content.len;

    self.req.respond(content, self.respond_options()) catch |err| {
        log.warn("C{}: Closing connection (failed to send error response: {})", .{ self.connection_number, err });
        if (@errorReturnTrace()) |ert| std.debug.dumpStackTrace(ert.*);
        return error.CloseConnection;
    };
}

pub fn format_err_response(options: Respond_Err_Options) ![]const u8 {
    if (options.empty_content) return "";

    const alloc = server.temp.allocator();
    var content = std.ArrayList(u8).init(alloc);
    var w = content.writer();

    try w.print(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>{} {s}</title></head>
        \\<body>
        \\<h1>{} {s}</h1>
        \\
        , .{
            @intFromEnum(options.status),
            options.status.phrase() orelse "",
            @intFromEnum(options.status),
            options.status.phrase() orelse "",
        });

    if (options.err) |err| {
        try w.print("<h3>{s}</h3>\n", .{ @errorName(err) });
    }

    if (options.trace) |ert| {
        try w.writeAll("<pre>\n");
        const debug_info = try std.debug.getSelfDebugInfo();
        try std.debug.writeStackTrace(ert.*, w, alloc, debug_info, .no_color);
        try w.writeAll("</pre>\n");
    }

    try w.writeAll(
        \\</body>
        \\</html>
        \\
        );

    return content.items;
}

fn maybe_respond_err(self: *Request, options: Respond_Err_Options) error{CloseConnection}!void {
    if (self.response_state != .not_started) return;
    self.respond_err(options) catch |err| {
        if (err != error.CloseConnection) {
            log.err("C{}: Closing connection (failed to send response: {})", .{ self.connection_number, err });
            if (@errorReturnTrace()) |ert| std.debug.dumpStackTrace(ert.*);
        }
        return error.CloseConnection;
    };
}

const log = std.log.scoped(.http);

const content_type = @import("content_type.zig");
const server = @import("server.zig");
const util = @import("util.zig");
const tempora = @import("tempora");
const std = @import("std");
