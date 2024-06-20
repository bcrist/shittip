/// usage:
///    hash_file <basename> <input_path> <compressed_output_path> <hash_metadata_output_path>

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const Hash = std.crypto.hash.sha2.Sha256;
const Digest = [Hash.digest_length]u8;

pub fn main() !void {
    defer std.debug.assert(.ok == gpa.deinit());

    var arg_iter = try std.process.argsWithAllocator(gpa.allocator());
    defer arg_iter.deinit();

    _ = arg_iter.next(); // command name
    const original_path = try arena.allocator().dupe(u8, arg_iter.next() orelse return error.MissingOriginalPath);
    std.mem.replaceScalar(u8, original_path, '\\', '/');

    const input_path = arg_iter.next() orelse return error.MissingInputPath;
    const content = try std.fs.cwd().readFileAlloc(gpa.allocator(), input_path, 100_000_000);
    defer gpa.allocator().free(content);

    var hash: Digest = undefined;
    Hash.hash(content, &hash, .{});

    const compressed_output_path = arg_iter.next() orelse return error.MissingCompressedOutputPath;
    const f = try std.fs.cwd().createFile(compressed_output_path, .{});
    defer f.close();

    var stream = std.io.fixedBufferStream(content);
    try std.compress.zlib.compress(stream.reader(), f.writer(), .{ .level = .level_9 });


    const hash_output_path = arg_iter.next() orelse return error.MissingHashOutputPath;
    try std.fs.cwd().writeFile(.{
        .sub_path = hash_output_path,
        .data = try std.fmt.allocPrint(arena.allocator(), "{s}\n{s}\n{s}\n", .{
            original_path,
            std.fs.path.basename(compressed_output_path),
            std.fmt.fmtSliceHexLower(&hash),
        }),
    });
}

const std = @import("std");
