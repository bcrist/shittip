/// usage:
///    hash_file <basename> <input_path> <compressed_output_path> <hash_metadata_output_path>

const Hash = std.crypto.hash.sha2.Sha256;
const Digest = [Hash.digest_length]u8;

pub fn main(init: std.process.Init) !void {
    var arg_iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer arg_iter.deinit();

    _ = arg_iter.next(); // command name
    const original_path = try init.arena.allocator().dupe(u8, arg_iter.next() orelse return error.MissingOriginalPath);
    std.mem.replaceScalar(u8, original_path, '\\', '/');

    const input_path = arg_iter.next() orelse return error.MissingInputPath;
    const content = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, init.arena.allocator(), .limited(100_000_000));

    var hash: Digest = undefined;
    Hash.hash(content, &hash, .{});

    const compressed_output_path = arg_iter.next() orelse return error.MissingCompressedOutputPath;
    {
        const f = try std.Io.Dir.cwd().createFile(init.io, compressed_output_path, .{});
        defer f.close(init.io);

        var writer_buf: [16384]u8 = undefined;
        var writer = f.writer(init.io, &writer_buf);

        var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var compressor = try std.compress.flate.Compress.init(&writer.interface, &flate_buf, .zlib, .best);
        try compressor.writer.writeAll(content);
        try compressor.writer.flush();
        try writer.interface.flush();
    }

    const hash_output_path = arg_iter.next() orelse return error.MissingHashOutputPath;
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = hash_output_path,
        .data = try std.fmt.allocPrint(init.arena.allocator(), "{s}\n{s}\n{x}\n", .{
            original_path,
            std.Io.Dir.path.basename(compressed_output_path),
            &hash,
        }),
    });
}

const std = @import("std");
