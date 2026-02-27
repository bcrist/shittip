group: std.Io.Group, // tasks for handling individual connections are added to this group
mutex: std.Io.Mutex, // prevents races between accepting a new connection and Loop.run() cancelling the group

pub const init: Server_Tasks = .{
    .group = .init,
    .mutex = .init,
};

const Server_Tasks = @This();

const std = @import("std");
