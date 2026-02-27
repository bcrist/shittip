pub const Comptime_Options = struct {
    /// Determines the maximum size of HTTP headers that can be accepted.
    connection_read_buffer_bytes: usize = 64 * 1024,
    connection_write_buffer_bytes: usize = 4 * 1024,
    request_scratch_buffer_bytes: usize = 4 * 1024,
    temp_allocator_usage_contraction_rate: u16 = 16,
    temp_allocator_usage_expansion_rate: u16 = 32,
    temp_allocator_fast_usage_expansion_rate: u16 = 128,

    // When using std.Io.Threaded, thread stack size must be greater than connection_read_buffer_bytes + connection_write_buffer_bytes + request_scratch_buffer_bytes
};

pub const Start_Options = struct {
    listen_options: std.Io.net.IpAddress.ListenOptions = .{},
    stop_loop_on_listen_failure: bool = true,
    temp_allocator_pool_size: usize = 16,
    temp_allocator_reservation_size: usize = 100 * 1024 * 1024,
    request_timeout: ?std.Io.Duration = .fromSeconds(30), // Not yet implemented
};

pub const Lookup_And_Start_Options = struct {
    family: ?std.Io.net.IpAddress.Family = null,
    interface: ?std.Io.net.Interface = null,
    start_options: Start_Options = .{},
};

pub fn Server(comptime Injector_Type: type, comptime comptime_options: Comptime_Options) type {
    const Injector_Context = if (Injector_Type.Input == *Request) void else T: {
        const Input = Injector_Type.Input;
        const info = @typeInfo(Input);
        if (info != .@"struct" or info.@"struct".fields.len != 2 or !@hasField(info, "request") or !@hasField(info, "context") or @FieldType(Input, "request") != *Request) {
            @compileError("Injector.Input must be `*http.Request` or `struct { request: *http.Request, context: *T }`");
        }
        const ptr_info = @typeInfo(@FieldType(Input, "context"));
        if (ptr_info != .pointer or ptr_info.pointer.size != .one) {
            @compileError("Injector.Input must be `*http.Request` or `struct { request: *http.Request, context: *T }`");
        }
        break :T ptr_info.pointer.child;
    };
    return struct {
        loop: *Loop,
        registry: std.StringHashMapUnmanaged(std.ArrayList(Handler_Func)),
        tasks: Server_Tasks,
        injector_context: Injector_Context,
        server_num: ?usize,
        index_pool: Index_Pool,
        temp_allocators: std.ArrayList(Temp_Allocator),

        pub const Injector = Injector_Type;

        const Self = @This();

        pub const init = if (Injector_Context == void) init_void else init_context;
        
        pub fn init_context(loop: *Loop, injector_context: Injector_Context) Self {
            return .{
                .loop = loop,
                .registry = .empty,
                .tasks = .init,
                .injector_context = injector_context,
                .server_num = null,
                .index_pool = .init,
                .temp_allocators = .empty,
            };
        }

        fn init_void(loop: *Loop) Self {
            return .{
                .loop = loop,
                .registry = .empty,
                .tasks = .init,
                .injector_context = {},
                .server_num = null,
                .index_pool = .init,
                .temp_allocators = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            if (@typeInfo(Injector_Context) == .@"struct" and @hasDecl(Injector_Context, "deinit") and @typeInfo(Injector_Context.deinit).@"fn".params.len == 1) {
                self.injector_context.deinit();
            }

            for (self.temp_allocators.items) |*ta| {
                ta.deinit();
            }

            self.temp_allocators.deinit(self.loop.gpa);

            self.index_pool.deinit(self.loop.gpa);

            var iter = self.registry.valueIterator();
            while (iter.next()) |list| {
                list.deinit(self.loop.gpa);
            }

            self.registry.deinit(self.loop.gpa);
        }

        /// `flow` must remain valid for the lifetime of the server (as well as `handler_func`, obviously)
        pub fn register(self: *Self, flow: []const u8, comptime handler_func: anytype) !void {
            const result = try self.registry.getOrPut(self.loop.gpa, flow);
            if (!result.found_existing) {
                result.key_ptr.* = flow;
                result.value_ptr.* = .empty;
            }

            try result.value_ptr.append(self.loop.gpa, struct {
                pub fn handle(request: *Request, ctx: *anyopaque) anyerror!void {
                    if (Injector_Context == void) {
                        try Injector.call(handler_func, request);
                    } else {
                        const injector_context: *Injector_Context = @ptrCast(ctx);
                        try Injector.call(handler_func, .{
                            .request = request,
                            .context = injector_context,
                        });
                    }
                }
            }.handle);
        }

        pub fn router(self: *Self, comptime prefix: []const u8, comptime routes: anytype) !void {
            return routing.router(self, prefix, routes);
        }

        pub fn lookup_and_start(self: *Self, ip_or_hostname: []const u8, port: u16, options: Lookup_And_Start_Options) !void {
            self.lookup_and_start_inner(ip_or_hostname, port, options) catch |err| {
                if (options.start_options.stop_loop_on_listen_failure) {
                    self.loop.stop();
                }
                return err;
            };
        }

        fn lookup_and_start_inner(self: *Self, ip_or_hostname: []const u8, port: u16, options: Lookup_And_Start_Options) !void {
            if (options.family) |family| {
                switch (family) {
                    .ip4 => if (std.Io.net.Ip4Address.parse(ip_or_hostname, port)) |ip| {
                        return try self.start(.{ .ip4 = ip }, options.start_options);
                    } else |_| {},
                    .ip6 => if (std.Io.net.Ip6Address.resolve(self.loop.io, ip_or_hostname, port)) |ip| {
                        return try self.start(.{ .ip6 = ip }, options.start_options);
                    } else |err| switch (err) {
                        error.Canceled => |e| return e,
                        else => {},
                    },
                }
            } else {
                if (std.Io.net.IpAddress.resolve(self.loop.io, ip_or_hostname, port)) |ip| {
                    return try self.start(ip, options.start_options);
                } else |err| switch (err) {
                    error.Canceled => |e| return e,
                    else => {},
                }
            }

            const hostname = try std.Io.net.HostName.init(ip_or_hostname);
            var canonical_name_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
            var results_buf: [32]std.Io.net.HostName.LookupResult = undefined;
            var results: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&results_buf);
            try hostname.lookup(self.loop.io, &results, .{
                .port = port,
                .family = options.family,
                .canonical_name_buffer = &canonical_name_buffer,
            });

            var listeners_started: usize = 0;

            while (results.getOne(self.loop.io)) |result| switch (result) {
                .canonical_name => {},
                .address => |ip| {
                    if (options.interface == null or (ip == .ip6 and ip.ip6.interface.index == options.interface.?.index)) {
                        if (self.start(ip, options.start_options)) {
                            listeners_started += 1;
                        } else |err| switch (err) {
                            error.Canceled => |e| return e,
                            error.ConcurrencyUnavailable => |e| return e,
                            else => log.err("S{?d}: Failed to listen on {f}: {}", .{ self.server_num, ip, err }),
                        }
                    }
                },
            } else |err| switch (err) {
                error.Closed => {},
                error.Canceled => |e| return e,
            }

            if (listeners_started == 0) {
                return error.NoListenableAddresses;
            }
        }

        pub fn start(self: *Self, address: std.Io.net.IpAddress, options: Start_Options) !void {
            if (self.server_num == null) {
                self.server_num = try self.loop.add(&self.tasks);
            }

            self.tasks.mutex.lockUncancelable(self.loop.io);
            defer self.tasks.mutex.unlock(self.loop.io);

            try self.index_pool.reset(self.loop.gpa, options.temp_allocator_pool_size);

            if (self.temp_allocators.items.len > options.temp_allocator_pool_size) {
                for (self.temp_allocators.items[options.temp_allocator_pool_size..]) |*ta| {
                    ta.deinit();
                }
                self.temp_allocators.shrinkRetainingCapacity(options.temp_allocator_pool_size);
            } else if (self.temp_allocators.items.len < options.temp_allocator_pool_size) {
                try self.temp_allocators.ensureTotalCapacityPrecise(self.loop.gpa, options.temp_allocator_pool_size);
                while (self.temp_allocators.items.len < options.temp_allocator_pool_size) {
                    self.temp_allocators.appendAssumeCapacity(try .init(options.temp_allocator_reservation_size));
                }
            }

            var server = address.listen(self.loop.io, options.listen_options) catch |err| {
                if (options.stop_loop_on_listen_failure) {
                    self.loop.stop();
                }
                return err;
            };
            errdefer server.deinit(self.loop.io);

            self.tasks.group.concurrent(self.loop.io, listener, .{ self, self.server_num.?, server, options.request_timeout }) catch |err| {
                if (options.stop_loop_on_listen_failure) {
                    self.loop.stop();
                }
                return err;
            };
        }

        fn listener(self: *Self, server_num: usize, incoming_server: std.Io.net.Server, request_timeout: ?std.Io.Duration) std.Io.Cancelable!void {
            const io = self.loop.io;

            var server = incoming_server;
            defer server.deinit(io);

            log.debug("S{d}: Now listening for connections on {f}...", .{ server_num, server.socket.address });

            self.loop.wait_state_end(.starting);

            var cid: Connection_Id = .init(server_num);
            while (true) {
                const stream = server.accept(io) catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    error.WouldBlock => {
                        try io.sleep(.fromMilliseconds(1), .awake);
                        continue;
                    },
                    error.ConnectionAborted => {
                        log.debug("{f}: Connection request was aborted remotely before the connection could be established", .{ cid });
                        continue;
                    },
                    else => {
                        log.err("{f}: Failed to accept new connection: {}", .{ cid, err });
                        self.loop.stop();
                        return;
                    },
                };
                log.info("{f}: connection from {f}", .{ cid, stream.socket.address });

                try self.tasks.mutex.lock(io);
                defer self.tasks.mutex.unlock(io);

                if (self.loop.state() != .running) {
                    stream.close(io);
                    log.debug("{f}: Closing connection: server is shutting down", .{ cid });
                    return;
                }

                self.tasks.group.concurrent(io, process_connection, .{ self, cid, stream, request_timeout }) catch |err| {
                    stream.close(io);
                    log.debug("{f}: Closing connection: {}", .{ cid, err });
                };

                cid = cid.next();
            }
        }

        fn process_connection(self: *Self, cid: Connection_Id, stream: std.Io.net.Stream, request_timeout: ?std.Io.Duration) void {
            const io = self.loop.io;
            defer stream.close(io);

            var reader_buf: [comptime_options.connection_read_buffer_bytes]u8 = undefined;
            var reader = stream.reader(io, &reader_buf);

            var writer_buf: [comptime_options.connection_write_buffer_bytes]u8 = undefined;
            var writer = stream.writer(io, &writer_buf);

            var http_server = std.http.Server.init(&reader.interface, &writer.interface);

            const ctx: Handler_Context = .{
                .cid = cid,
                .server = &http_server,
                .reader = &reader,
                .writer = &writer,
            };

            while (http_server.reader.state == .ready) {
                const request = http_server.receiveHead() catch |err| switch (err) {
                    error.HttpHeadersOversize => {
                        log.info("{f}: [431] Expected request headers to be <= {B}", .{ cid, comptime_options.connection_read_buffer_bytes });
                        http_server.out.writeAll("HTTP/1.0 431 Request Header Fields Too Large\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch |response_err| {
                            ctx.log_error("Failed to write response", response_err, @errorReturnTrace());
                            return;
                        };
                        http_server.out.flush() catch |response_err| {
                            ctx.log_error("Failed to write response", response_err, @errorReturnTrace());
                            return;
                        };
                        log.info("{f}: Closing connection (sent 431)", .{ cid });
                        return;
                    },
                    error.HttpHeadersInvalid => {
                        log.info("{f}: Closing connection (client sent invalid request)", .{ cid });
                        return;
                    },
                    error.HttpRequestTruncated => {
                        log.debug("{f}: Closing connection (client closed before finishing headers)", .{ cid });
                        return;
                    },
                    error.HttpConnectionClosing => {
                        log.debug("{f}: Closing connection normally (client closed first)", .{ cid });
                        return;
                    },
                    error.ReadFailed => {
                        ctx.log_error("Failed to read headers", err, @errorReturnTrace());
                        return;
                    },
                };

                const timeout: std.Io.Timeout = if (request_timeout) |duration| .{ .duration = .{ .clock = .awake, .raw = duration } } else .none;
                // TODO https://codeberg.org/ziglang/zig/issues/31098
                _ = timeout;
                var proc = self.loop.io.concurrent(process_request, .{ self, ctx, request }) catch {
                    log.info("{f}: Closing connection (insufficient concurrency available)", .{ cid });
                    return;
                };
                proc.await(self.loop.io);
                if (http_server.reader.state != .ready) {
                    log.info("{f}: Closing connection (handler failed)", .{ cid });
                }
            }
        }

        fn process_request(self: *Self, ctx: Handler_Context, req: std.http.Server.Request) void {
            log.debug("{f}: {t} {s}", .{ ctx.cid, req.head.method, req.head.target });
            defer log.debug("{f}: Finished processing request", .{ ctx.cid });

            const dt = tempora.now(self.loop.io).dt;

            var response_arena: std.heap.ArenaAllocator = .init(self.loop.gpa);
            defer response_arena.deinit();

            // used for Request.handlers and Request.response.headers lists, and Request.fmt_http_date
            var scratch_alloc = std.heap.stackFallback(comptime_options.request_scratch_buffer_bytes, response_arena.allocator());

            var request: Request = .{
                .io = self.loop.io,
                .arena = response_arena.allocator(),
                .cid = ctx.cid,
                .req = req,
                .received_dt = dt,
                .content_type = if (req.head.content_type) |ct| .parse(ct) else null,
                .target = .parse(req.head.target),
                .handlers = .empty,
                .response = .{
                    .headers = .empty,
                    .version = req.head.version,
                    .status = .ok,
                    .reason = null,
                    .keep_alive = true,
                    .transfer_encoding = null,
                    .content_length = null,
                    .buffer_bytes = 65536,
                    .state = .not_started,
                },
                .internal = .{
                    .loop = self.loop,
                    .registry = &self.registry,
                    .body = null,
                    .decompress = undefined,
                    .header_strings_cloned = false,
                    .ta_pool = .{
                        .pool = &self.index_pool,
                        .allocators = self.temp_allocators.items,
                        .index = null,
                    },
                    .head_buffer = req.head_buffer,
                    .scratch_alloc = scratch_alloc.get(),
                },
            };

            defer if (request.internal.ta_pool.index) |index| {
                const ta = &self.temp_allocators.items[index];
                const final_usage = ta.snapshot();
                const high_water = ta.high_water_usage();
                const committed = ta.committed();
                const reserved = ta.reservation.len;
                const prev_estimate = ta.usage_estimate;
                ta.reset(.{
                    .usage_contraction_rate = comptime_options.temp_allocator_usage_contraction_rate,
                    .usage_expansion_rate = comptime_options.temp_allocator_usage_expansion_rate,
                    .fast_usage_expansion_rate = comptime_options.temp_allocator_fast_usage_expansion_rate,
                });
                const new_committed = ta.committed();
                const new_estimate = ta.usage_estimate;
                self.index_pool.release(index);
                log.debug("{f}: temp usage: final={d}  high water={d}  prev_estimate={d}  d_estimate={d}  released={d}  committed={d}  reserved={d}", .{
                    ctx.cid,
                    fmt.bytes(final_usage),
                    fmt.bytes(high_water),
                    fmt.bytes(prev_estimate),
                    fmt.bytes_signed(@as(isize, @intCast(new_estimate)) - @as(isize, @intCast(prev_estimate))),
                    fmt.bytes(committed - new_committed),
                    fmt.bytes(new_committed),
                    fmt.bytes(reserved),
                });
            };

            request.handle(&self.injector_context, "") catch |err| {
                if (err == error.Done) return;
                if (status_from_error(err)) |status| {
                    request.maybe_respond_err(.{ .status = status }) catch |response_err| {
                        ctx.log_error("Failed to write response", response_err, @errorReturnTrace());
                        ctx.server.reader.state = .closing;
                    };
                } else {
                    request.maybe_respond_err(switch (err) {
                        error.Canceled, error.InsufficientResources, error.OutOfMemory => .{
                            .status = .service_unavailable,
                        },
                        else => .{
                            .err = err,
                            .trace = @errorReturnTrace(),
                        },
                    }) catch |response_err| {
                        ctx.log_error("Failed to write response", response_err, @errorReturnTrace());
                        ctx.server.reader.state = .closing;
                        return;
                    };
                    ctx.log_extra_errors();
                    ctx.server.reader.state = .closing;
                }
            };
        }
    };
}

fn status_from_error(err: anyerror) ?std.http.Status {
    return switch (err) {
        error.BadRequest => .bad_request,
        error.Unauthorized => .unauthorized,
        error.Forbidden => .forbidden,
        error.NotFound => .not_found,
        error.MethodNotAllowed => .method_not_allowed,
        error.NotAcceptable => .not_acceptable,
        error.Conflict => .conflict,
        error.Gone => .gone,
        error.LengthRequired => .length_required,
        error.PreconditionFailed => .precondition_failed,
        error.ContentTooLarge, error.PayloadTooLarge => .payload_too_large,
        error.UnsupportedMediaType => .unsupported_media_type,
        error.RangeNotSatisfiable => .range_not_satisfiable,
        error.ExpectationFailed => .expectation_failed,
        error.UnprocessableEntity => .unprocessable_entity,
        error.Locked => .locked,
        error.FailedDependency => .failed_dependency,
        error.TooEarly => .too_early,
        error.PreconditionRequired => .precondition_required,
        error.TooManyRequests => .too_many_requests,
        error.InternalServerError => .internal_server_error,
        error.NotImplemented => .not_implemented,
        error.ServiceUnavailable => .service_unavailable,
        error.InsufficientStorage => .insufficient_storage,
        else => null,
    };
}

const Handler_Context = struct {
    cid: Connection_Id,
    reader: *std.Io.net.Stream.Reader,
    writer: *std.Io.net.Stream.Writer,
    server: *std.http.Server,

    pub fn log_error(ctx: Handler_Context, comptime msg: []const u8, err: anyerror, maybe_trace: ?*std.builtin.StackTrace) void {
        log.warn("{f}: " ++ msg ++ ": {}", .{ ctx.cid, err });

        if (maybe_trace) |trace| {
            std.debug.dumpStackTrace(trace);
        }

        ctx.log_extra_errors();
    }

    pub fn log_extra_errors(ctx: Handler_Context) void {
        if (ctx.reader.err) |rerr| switch (rerr) {
            error.ConnectionResetByPeer, error.Timeout => {
                log.debug("{f}: Failed to read request: {}", .{ ctx.cid, rerr });
            },
            else => {
                log.warn("{f}: Failed to read request: {}", .{ ctx.cid, rerr });
            },
        };

        if (ctx.server.reader.body_err) |rerr| {
            log.warn("{f}: Failed to read request body: {}", .{ ctx.cid, rerr });
        }

        if (ctx.writer.err) |werr| switch (werr) {
            error.ConnectionResetByPeer => {
                log.debug("{f}: Failed to write response: {}", .{ ctx.cid, werr });
            },
            else => {
                log.warn("{f}: Failed to write response: {}", .{ ctx.cid, werr });
            },
        };

        if (ctx.writer.write_file_err) |werr| {
            log.warn("{f}: Failed to write response: {}", .{ ctx.cid, werr });
        }
    }
};

pub const Handler_Func = *const fn (*Request, *anyopaque) anyerror!void;

const log = std.log.scoped(.http);

const routing = @import("routing.zig");
const Request = @import("Request.zig");
const Loop = @import("Loop.zig");
const Connection_Id = @import("Connection_Id.zig");
const Server_Tasks = @import("Server_Tasks.zig");
const Index_Pool = @import("Index_Pool.zig");
const Temp_Allocator = @import("Temp_Allocator");
const tempora = @import("tempora");
const fmt = @import("fmt");
const std = @import("std");
