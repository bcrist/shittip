pub const Options = struct {
    address: std.net.Address,
    listen_options: std.net.Address.ListenOptions = .{},
    connection_threads: ?u32 = 10,
    max_temp_bytes_per_request: usize = 100 * 1024 * 1024,
    receive_timeout_seconds: i32 = 30,
};

pub fn Server(comptime Injector: type) type {
    return struct {
        registry: Registry,
        pool: Pool,
        started: bool,
        listener: std.net.Server,
        receive_timeout_seconds: i32,

        const Self = @This();
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .registry = Registry.init(allocator),
                .pool = .{ .allocator = allocator },
                .started = false,
                .listener = undefined,
                .receive_timeout_seconds = undefined,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.started) self.listener.deinit();
            
            self.pool.deinit();

            const allocator = self.registry.allocator;
            var iter = self.registry.valueIterator();
            while (iter.next()) |list| {
                list.deinit(allocator);
            }

            self.registry.deinit();
        }

        pub fn register(self: *Self, flow: []const u8, comptime handler_func: anytype) !void {
            const result = try self.registry.getOrPut(flow);
            if (!result.found_existing) {
                result.key_ptr.* = flow;
                result.value_ptr.* = .{};
            }

            try result.value_ptr.append(self.registry.allocator, struct {
                pub fn handle() anyerror!void {
                    try Injector.call(handler_func, {});
                }
            }.handle);
        }

        pub fn router(self: *Self, comptime prefix: []const u8, comptime routes: anytype) !void {
            return routing.router(self, prefix, routes);
        }

        pub fn start(self: *Self, options: Options) !void {
            const thread_init_task = try self.pool.shared_task(worker_thread_init, .{
                &self.pool,
                &self.registry,
                options.max_temp_bytes_per_request,
            });
            const thread_deinit_task = self.pool.shared_task(worker_thread_deinit, .{}) catch |err| {
                thread_init_task.deinit_func(thread_init_task);
                return err;
            };

            try self.pool.start(.{
                .num_threads = options.connection_threads,
                .thread_init = thread_init_task,
                .thread_deinit = thread_deinit_task,
            });
            
            log.debug("Initialized thread pool ({} threads)", .{
                self.pool.threads.len,
            });

            self.listener = try options.address.listen(options.listen_options);
            self.receive_timeout_seconds = options.receive_timeout_seconds;
            self.started = true;
        }

        pub fn stop(self: *Self) void {
            self.pool.stop();
        }

        pub fn run(self: *Self) !void {
            var connection_num: usize = 1;
            log.debug("Waiting for connection", .{});
            while (self.pool.is_running()) {
                const connection = self.listener.accept() catch |err| switch (err) {
                    error.WouldBlock => {
                        std.Thread.yield() catch {};
                        continue;
                    },
                    error.ConnectionResetByPeer => {
                        log.info("Connection request was aborted remotely before the connection could be established", .{});
                        continue;
                    },
                    else => return err,
                };
                log.info("C{}: connection from {}", .{
                    connection_num,
                    connection.address,
                });

                const timeout: std.posix.timeval = .{
                    .tv_sec = self.receive_timeout_seconds,
                    .tv_usec = 0,
                };
                std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
                    log.warn("C{}: Failed to set socket receive timeout: {}", .{ connection_num, err });
                };

                try self.pool.submit(handle_connection, .{ connection_num, connection });
                connection_num +%= 1;
            }
        }

        fn handle_connection(connection_num: usize, connection: std.net.Server.Connection) void {
            var header_buf: [65536]u8 = undefined;
            var server = std.http.Server.init(connection, &header_buf);
            defer server.connection.stream.close();

            log.debug("C{}: Assigned to thread {}", .{ connection_num, std.Thread.getCurrentId() });

            while (server.state == .ready and thread_pool.is_running()) {
                defer {
                    const final_usage = temp.snapshot();
                    const high_water = temp.high_water_usage();
                    const committed = temp.committed();
                    const reserved = temp.reservation.len;
                    const prev_estimate = temp.usage_estimate;
                    temp.reset(.{
                        .usage_contraction_rate = 16,
                        .usage_expansion_rate = 32,
                        .fast_usage_expansion_rate = 128,
                    });
                    const new_committed = temp.committed();
                    const new_estimate = temp.usage_estimate;
                    log.debug("Thread {} temp usage: final={d}  high water={d}  prev_estimate={d}  d_estimate={d}  released={d}  committed={d}  reserved={d}", .{
                        std.Thread.getCurrentId(),
                        fmt.fmtBytes(final_usage),
                        fmt.fmtBytes(high_water),
                        fmt.fmtBytes(prev_estimate),
                        fmt.fmtBytesSigned(@as(isize, @intCast(new_estimate)) - @as(isize, @intCast(prev_estimate))),
                        fmt.fmtBytes(committed - new_committed),
                        fmt.fmtBytes(new_committed),
                        fmt.fmtBytes(reserved),
                    });
                }
                request = .{
                    .connection_number = connection_num,
                    .req = server.receiveHead() catch |err| switch (err) {
                        error.HttpHeadersOversize => {
                            log.info("C{}: [431] Expected request headers to be <= 64KB", .{ connection_num });
                            server.connection.stream.writeAll(
                                "HTTP/1.0 431 Request Header Fields Too Large\r\n" ++
                                "connection: close\r\n" ++
                                "content-length: 0\r\n\r\n") catch |write_err| {
                                log.info("C{}: Closing connection (failed to send 431 Request Header Fields Too Large: {})", .{ connection_num, write_err });
                                return;
                            };
                            log.info("C{}: Closing connection (sent 431)", .{ connection_num });
                            return;
                        },
                        error.HttpHeadersInvalid => {
                            log.info("C{}: Closing connection (client closed before finishing headers)", .{ connection_num });
                            return;
                        },
                        error.HttpHeadersUnreadable => {
                            // Most likely cause is the receive timeout was exceeded.
                            // Hopefully in the future std.http.Server will expose that as a unique error.
                            log.info("C{}: Closing connection (timeout or other error while trying to read headers)", .{ connection_num });
                            return;
                        },
                        error.HttpRequestTruncated => {
                            log.info("C{}: Closing connection (client closed before finishing headers)", .{ connection_num });
                            return;
                        },
                        error.HttpConnectionClosing => {
                            log.debug("C{}: Closing connection normally (client closed first)", .{ connection_num });
                            return;
                        },
                    },
                    .handlers = Request.Handler_Fifo.init(temp.allocator()),
                    .response_headers = std.ArrayList(std.http.Header).init(temp.allocator()),
                    .received_dt = tempora.now().dt,
                };
                request.handle() catch return;
            }
        }

        



            //     if (maybe_handler) |handler| {
            //         handler(request) catch |err| switch (err) {
            //             error.CloseConnection => return err,
            //             error.BadRequest => try respond_err(request, .{ .status = .bad_request }),
            //             else => try respond_err(request, .{ .err = err, .trace = @errorReturnTrace() }),
            //         };
            //     } else {
            //         try respond_err(request, .{ .status = .method_not_allowed });
            //     }
            // } else {
            //     try respond_err(request, .{ .status = .not_found });
            // }
    };
}

fn worker_thread_init(pool: *Pool, reg: *const Registry, max_temp_bytes_per_request: usize) void {
    temp = Temp_Allocator.init(max_temp_bytes_per_request) catch
        @panic("Failed to reserve address space for thread temp allocator; decrease connection_threads or max_temp_bytes_per_request!");
    thread_pool = pool;
    registry = reg;
}

fn worker_thread_deinit() void {
    temp.deinit();
    temp = undefined;
    thread_pool = undefined;
    registry = undefined;
    request = undefined;
}

pub threadlocal var temp: Temp_Allocator = undefined;
pub threadlocal var thread_pool: *Pool = undefined;
pub threadlocal var registry: *const Registry = undefined;
pub threadlocal var request: Request = undefined;

pub const Registry = std.StringHashMap(std.ArrayListUnmanaged(Request.Handler_Func));

const log = std.log.scoped(.http);

const routing = @import("routing.zig");
const Request = @import("Request.zig");
const Pool = @import("Pool.zig");
const Temp_Allocator = @import("Temp_Allocator");
const tempora = @import("tempora");
const fmt = @import("fmt");
const std = @import("std");
