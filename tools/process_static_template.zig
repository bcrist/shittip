/// usage:
///    process_static_template <input_file> <output_file> <depfile_path> [[-t <extension>]... <search_path>]...

pub fn main(init: std.process.Init) !void {
    var stderr_buf: [64]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);

    var cache: Resource_File.Cache = .{
        .arena = init.arena.allocator(),
        .gpa = init.gpa,
        .io = init.io,
        .diagnostic_writer = &stderr.interface,
    };
    defer cache.deinit();

    var arg_iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer arg_iter.deinit();

    _ = arg_iter.next(); // exe name
    const in_path = arg_iter.next() orelse return error.ExpectedInputPath;
    const out_path = arg_iter.next() orelse return error.ExpectedOutputPath;
    const depfile_path = arg_iter.next() orelse return error.ExpectedDepfilePath;

    var template_extensions: std.ArrayList([]const u8) = .empty;
    defer template_extensions.deinit(init.gpa);

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-t")) {
            const ext = arg_iter.next() orelse return error.ExpectedTemplateExtension;
            try template_extensions.append(init.gpa, ext);
        } else {
            try cache.add_dir(arg, template_extensions.items);
            template_extensions.clearRetainingCapacity();
        }
    }

    var in_file: Resource_File = .{
        .cache = &cache,
        .realpath = in_path,
        .source = .{
            .template = try zkittle.Source.init_file(init.arena.allocator(), init.io, std.Io.Dir.cwd(), in_path),
        },
    };

    const data = try in_file.compute_output(init.arena.allocator());
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = out_path,
        .data = data,
    });

    const depfile = try std.Io.Dir.cwd().createFile(init.io, depfile_path, .{});
    defer depfile.close(init.io);

    var depfile_buf: [4096]u8 = undefined;
    var depfile_writer = depfile.writer(init.io, &depfile_buf);
    const dw = &depfile_writer.interface;
    try dw.print("\"{s}\":", .{ out_path });

    for (cache.files.values()) |file| {
        if (std.mem.indexOfScalar(u8, file.realpath, '#') == null) {
            try dw.print(" \"{s}\"", .{ file.realpath });
        }
    }

    try dw.flush();
    
    try stderr.interface.flush();
}

const Resource_File = @import("Resource_File.zig");
const zkittle = @import("zkittle");
const std = @import("std");
