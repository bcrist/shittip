server_num: usize,
connection_num: usize,

pub fn init(server_num: usize) Connection_Id {
    return .{
        .server_num = server_num,
        .connection_num = 1,
    };
}

pub fn next(self: Connection_Id) Connection_Id {
    return .{
        .server_num = self.server_num,
        .connection_num = self.connection_num +% 1,
    };
}

pub fn format(self: Connection_Id, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("S{d} C{d}", .{ self.server_num, self.connection_num });
}

const Connection_Id = @This();

const std = @import("std");
