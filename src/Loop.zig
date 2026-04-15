s: State,
io: std.Io,
gpa: std.mem.Allocator,
servers: std.ArrayList(*Server_Tasks),
servers_mutex: std.Io.Mutex,

pub const State = enum (u32) {
    stopped,
    starting,
    running,
    stopping,
};

pub fn init(io: std.Io, gpa: std.mem.Allocator) Loop {
    return .{
        .s = .stopped,
        .io = io,
        .gpa = gpa,
        .servers = .empty,
        .servers_mutex = .init,
    };
}

pub fn deinit(self: *Loop) void {
    std.debug.assert(self.s == .stopped);
    self.servers.deinit(self.gpa);
}

pub fn add(self: *Loop, tasks: *Server_Tasks) !usize {
    try self.servers_mutex.lock(self.io);
    defer self.servers_mutex.unlock(self.io);

    try self.servers.append(self.gpa, tasks);
    return self.servers.items.len;
}

pub fn state(self: *const Loop) State {
    return @atomicLoad(State, &self.s, .acquire);
}

fn change_state(self: *Loop, current: State, new: State) void {
    if (@cmpxchgStrong(State, &self.s, current, new, .acq_rel, .acquire) == null) {
        self.io.futexWake(State, &self.s, std.math.maxInt(u32));
        switch (new) {
            .stopped => log.debug("Stopped.", .{}),
            .starting => log.debug("Starting...", .{}),
            .running => log.debug("Running...", .{}),
            .stopping => log.debug("Stopping...", .{}),
        }
    }
}

pub fn wait_state_end(self: *Loop, s: State) void {
    while (self.state() == s) {
        self.io.futexWaitUncancelable(State, &self.s, s);
    }
}

pub fn start(self: *Loop) void {
    self.change_state(.stopped, .starting);
}

pub fn begin_running(self: *Loop) void {
    self.change_state(.starting, .running);
}

pub fn stop(self: *Loop) void {
    self.change_state(.starting, .stopping);
    self.change_state(.running, .stopping);
}

pub fn finish_running(self: *Loop) void {
    self.wait_state_end(.running);

    self.servers_mutex.lockUncancelable(self.io);
    defer self.servers_mutex.unlock(self.io);

    for (self.servers.items) |tasks| {
        tasks.mutex.lockUncancelable(self.io);
        defer tasks.mutex.unlock(self.io);

        tasks.group.cancel(self.io);
    }

    self.change_state(.stopping, .stopped);
}

pub fn run(self: *Loop) void {
    self.begin_running();
    self.finish_running();
}

const log = std.log.scoped(.http);

const Loop = @This();

const Server_Tasks = @import("Server_Tasks.zig");
const std = @import("std");
