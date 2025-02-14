pub const Options = struct {
    address: std.net.Address,
    listen_options: std.net.Address.ListenOptions = .{},
    connection_threads: ?u32 = 100,
    worker_threads: ?u32 = 10,
    max_request_header_bytes: usize = 32 * 1024,
    max_temp_bytes_per_request: usize = 100 * 1024 * 1024,
    receive_timeout_seconds: i32 = 30,
};

pub fn Server(comptime Injector: type) type {
    return struct {
        registry: Registry,
        connection_pool: Pool,
        worker_pool: Pool,
        started: bool,
        listener: std.net.Server,
        receive_timeout_seconds: i32,

        const Self = @This();
        
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .registry = Registry.init(allocator),
                .connection_pool = .{ .allocator = allocator },
                .worker_pool = .{ .allocator = allocator },
                .started = false,
                .listener = undefined,
                .receive_timeout_seconds = undefined,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.started) self.listener.deinit();
            
            self.connection_pool.deinit();
            self.worker_pool.deinit();

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
            const worker_thread_init_task = try self.worker_pool.shared_task(worker_thread_init, .{
                Pools{
                    .connection_thread_pool = &self.connection_pool,
                    .worker_thread_pool = &self.worker_pool,
                },
                &self.registry,
                options.max_temp_bytes_per_request,
            });
            const worker_thread_deinit_task = self.worker_pool.shared_task(worker_thread_deinit, .{}) catch |err| {
                worker_thread_init_task.deinit_func(worker_thread_init_task);
                return err;
            };
            try self.worker_pool.start(.{
                .num_threads = options.worker_threads,
                .thread_init = worker_thread_init_task,
                .thread_deinit = worker_thread_deinit_task,
            });
            log.debug("Initialized worker thread pool ({} threads)", .{
                self.worker_pool.threads.len,
            });

            const connection_thread_init_task = try self.worker_pool.shared_task(connection_thread_init, .{
                Pools{
                    .connection_thread_pool = &self.connection_pool,
                    .worker_thread_pool = &self.worker_pool,
                },
                options.max_request_header_bytes,
            });
            const connection_thread_deinit_task = self.worker_pool.shared_task(connection_thread_deinit, .{}) catch |err| {
                connection_thread_init_task.deinit_func(connection_thread_init_task);
                return err;
            };
            try self.connection_pool.start(.{
                .num_threads = options.connection_threads,
                .thread_init = connection_thread_init_task,
                .thread_deinit = connection_thread_deinit_task,
            });
            log.debug("Initialized connection thread pool ({} threads)", .{
                self.connection_pool.threads.len,
            });

            self.listener = try options.address.listen(options.listen_options);
            self.receive_timeout_seconds = options.receive_timeout_seconds;
            self.started = true;
        }

        pub fn stop(self: *Self) void {
            self.connection_pool.stop();
            self.worker_pool.stop();
        }

        pub fn run(self: *Self) !void {
            var connection_num: usize = 1;
            log.debug("Waiting for connection", .{});
            while (self.connection_pool.is_running()) {
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
                    .sec = self.receive_timeout_seconds,
                    .usec = 0,
                };
                std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
                    log.warn("C{}: Failed to set socket receive timeout: {}", .{ connection_num, err });
                };

                self.connection_pool.submit(handle_connection, .{ connection_num, connection }) catch |err| {
                    connection.stream.close();
                    switch (err) {
                        error.PoolNotRunning => log.debug("C{}: failed to submit to connection thread pool; server is shutting down", .{ connection_num }),
                        else => return err,
                    }
                };
                connection_num +%= 1;
            }
        }

        fn handle_connection(connection_num: usize, connection: std.net.Server.Connection) void {
            log.debug("C{}: Assigned to connection thread {}", .{ connection_num, std.Thread.getCurrentId() });

            var server = std.http.Server.init(connection, request_header_buffer);
            defer server.connection.stream.close();

            var mtx: std.Thread.Mutex = .{};
            var cv: std.Thread.Condition = .{};

            mtx.lock();
            defer mtx.unlock();

            while (server.state == .ready and pools.connection_thread_pool.is_running()) {
                const req = server.receiveHead() catch |err| switch (err) {
                    error.HttpHeadersOversize => {
                        log.info("C{}: [431] Expected request headers to be <= {}", .{ connection_num, fmt.fmtBytes(request_header_buffer.len) });
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
                        log.info("C{}: Closing connection normally (client closed first)", .{ connection_num });
                        return;
                    },
                };

                pools.worker_thread_pool.submit(handle_request, .{ connection_num, req, &mtx, &cv }) catch |err| {
                    log.info("C{}: Closing connection (failed to submit request to worker thread pool: {})", .{ connection_num, err });
                    return;
                };
                cv.wait(&mtx);
            }
        }

        fn handle_request(connection_num: usize, req: std.http.Server.Request, mtx: *std.Thread.Mutex, cv: *std.Thread.Condition) void {
            mtx.lock();
            defer mtx.unlock();
            defer cv.signal();

            log.debug("C{}: Assigned to worker thread {}", .{ connection_num, std.Thread.getCurrentId() });
            defer log.debug("C{}: Finished handling request", .{ connection_num });

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
                temp_log.debug("Thread {} temp usage: final={d}  high water={d}  prev_estimate={d}  d_estimate={d}  released={d}  committed={d}  reserved={d}", .{
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
                .req = req,
                .handlers = Request.Handler_Fifo.init(temp.allocator()),
                .response_headers = std.ArrayList(std.http.Header).init(temp.allocator()),
                .received_dt = tempora.now().dt,
            };
            request.handle() catch {
                req.server.state = .closing;
            };
        }
    };
}

fn connection_thread_init(the_pools: Pools, max_request_header_bytes: usize) void {
    pools = the_pools;
    request_header_buffer = std.heap.page_allocator.alloc(u8, max_request_header_bytes) catch
        @panic("Failed to reserve request header buffer; decrease connection_threads or max_request_header_bytes!");
}
fn connection_thread_deinit() void {
    pools = undefined;
    std.heap.page_allocator.free(request_header_buffer);
    request_header_buffer = &.{};
}

fn worker_thread_init(the_pools: Pools, reg: *const Registry, max_temp_bytes_per_request: usize) void {
    pools = the_pools;
    temp = Temp_Allocator.init(max_temp_bytes_per_request) catch
        @panic("Failed to reserve address space for thread temp allocator; decrease worker_threads or max_temp_bytes_per_request!");
    registry = reg;
}
fn worker_thread_deinit() void {
    pools = undefined;
    temp.deinit();
    temp = undefined;
    registry = undefined;
    request = undefined;
}

pub const Pools = struct {
    connection_thread_pool: *Pool,
    worker_thread_pool: *Pool,
};

// Only valid for use on connection threads, not worker threads:
threadlocal var request_header_buffer: []u8 = &.{};

// Available on either connection or worker threads:
pub threadlocal var pools: Pools = undefined;

// Only valid for use on worker threads, not connection threads:
pub threadlocal var temp: Temp_Allocator = undefined;
pub threadlocal var registry: *const Registry = undefined;
pub threadlocal var request: Request = undefined;

pub const Registry = std.StringHashMap(std.ArrayListUnmanaged(Request.Handler_Func));

const log = std.log.scoped(.http);
const temp_log = std.log.scoped(.@"http.temp");

const routing = @import("routing.zig");
const Request = @import("Request.zig");
const Pool = @import("Pool.zig");
const Temp_Allocator = @import("Temp_Allocator");
const tempora = @import("tempora");
const fmt = @import("fmt");
const std = @import("std");
