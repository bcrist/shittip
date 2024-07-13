/// usage:
///    process_static_template <input_file> <output_file> <depfile_path> [[-t <extension>]... <search_path>]...

pub fn main() !void {
    defer std.debug.assert(.ok == gpa.deinit());
    
    var cache: Resource_File.Cache = .{
        .arena = arena.allocator(),
        .gpa = gpa.allocator(),
    };
    defer cache.deinit();

    var arg_iter = try std.process.argsWithAllocator(gpa.allocator());
    defer arg_iter.deinit();

    _ = arg_iter.next(); // exe name
    const in_path = arg_iter.next() orelse return error.ExpectedInputPath;
    const out_path = arg_iter.next() orelse return error.ExpectedOutputPath;
    const depfile_path = arg_iter.next() orelse return error.ExpectedDepfilePath;
    
    var template_extensions = std.ArrayList([]const u8).init(gpa.allocator());
    defer template_extensions.deinit();

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-t")) {
            const ext = try arena.allocator().dupe(u8, arg_iter.next() orelse return error.ExpectedTemplateExtension);
            try template_extensions.append(ext);
        } else {
            const path = try arena.allocator().dupe(u8, arg);
            try cache.add_dir(path, template_extensions.items);
            template_extensions.clearRetainingCapacity();
        }
    }

    var in_file: Resource_File = .{
        .cache = &cache,
        .realpath = in_path,
        .source = .{
            .template = try zkittle.Source.init_file(arena.allocator(), std.fs.cwd(), in_path),
        },
    };

    const data = try in_file.compute_output(arena.allocator());
    try std.fs.cwd().writeFile(.{
        .sub_path = out_path,
        .data = data,
    });

    const depfile = try std.fs.cwd().createFile(depfile_path, .{});
    defer depfile.close();

    var dw = depfile.writer();
    try dw.print("\"{s}\":", .{ out_path });

    for (cache.files.values()) |file| {
        if (std.mem.indexOfScalar(u8, file.realpath, '#') == null) {
            try dw.print(" \"{s}\"", .{ file.realpath });
        }
    }
}

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const Resource_File = @import("Resource_File.zig");
const zkittle = @import("zkittle");
const std = @import("std");
