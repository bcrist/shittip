cache: *Cache,
realpath: []const u8,
source: union (enum) {
    template: Template.Source,
    raw: []const u8,
},
output: ?[]const u8 = null,
digest: ?Digest = null,
http_path: ?[]const u8 = null,

const Resource_File = @This();

pub const Hash = std.crypto.hash.sha2.Sha256;
pub const Digest = [Hash.digest_length]u8;

pub const Cache = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    include_dirs: std.ArrayListUnmanaged(Directory) = .{},
    files: std.StringArrayHashMapUnmanaged(*Resource_File) = .{},

    pub const Directory = struct {
        path: []const u8,
        template_extensions: []const []const u8,
    };

    pub fn deinit(self: *Cache) void {
        self.files.deinit(self.gpa);
        self.include_dirs.deinit(self.gpa);
    }

    pub fn add_dir(self: *Cache, path: []const u8, template_extensions: []const []const u8) !void {
        const extensions = try self.arena.dupe([]const u8, template_extensions);
        for (extensions) |*ext| {
            ext.* = try self.arena.dupe(u8, ext.*);
        }
        try self.include_dirs.append(self.gpa, .{
            .path = try self.arena.dupe(u8, path),
            .template_extensions = extensions,
        });
    }

    pub fn get(self: *Cache, path: []const u8) !*Resource_File {
        if (self.files.get(path)) |file| return file;

        if (std.mem.indexOfScalar(u8, path, '#')) |frag_start| {
            const base_file = try self.get(path[0..frag_start]);
            const frag = path[frag_start + 1 ..];

            const source = switch (base_file.source) {
                .template => |src| src,
                .raw => return error.PathIsNotTemplate,
            };

            var temp = std.ArrayList(u8).init(self.gpa);
            defer temp.deinit();

            var parser: Template.Parser = .{
                .gpa = self.gpa,
                .callback_context = null,
                .include_callback = template_include,
                .resource_callback = template_resource,
            };
            defer parser.deinit();

            try parser.append(source);

            if (parser.fragments.get(frag)) |frag_info| {
                const content = try std.fmt.allocPrint(self.arena, "\\\\{s}", .{ frag_info.content });
                errdefer self.arena.free(content);

                var tokens = try Template.Token.lex(self.arena, content);
                errdefer tokens.deinit(self.arena);

                const realpath = try std.fmt.allocPrint(self.arena, "{s}#{s}", .{ base_file.realpath, frag });
                errdefer self.arena.free(realpath);

                const path_copy = try self.arena.dupe(u8, path);
                const file = try self.arena.create(Resource_File);
                file.* = .{
                    .cache = self,
                    .realpath = realpath,
                    .source = .{ .template = .{
                        .path = realpath,
                        .source = content,
                        .tokens = tokens,
                    }},
                };

                try self.files.put(self.gpa, path_copy, file);
                return file;
            }
            
            return error.InvalidTemplateFragment;
        }

        const ext = std.fs.path.extension(path);

        for (self.include_dirs.items) |dir_info| {
            var dir = try std.fs.cwd().openDir(dir_info.path, .{});
            defer dir.close();

            const stat = dir.statFile(path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };

            const realpath = try dir.realpathAlloc(self.arena, path);
            errdefer self.arena.free(realpath);

            const source = try dir.readFileAllocOptions(self.arena, realpath, 1_000_000_000, stat.size, 1, null);
            errdefer self.arena.free(source);

            const is_template = for (dir_info.template_extensions) |template_ext| {
                if (std.mem.eql(u8, template_ext, ext)) break true;
            } else false;

            const path_copy = try self.arena.dupe(u8, path);
            const file = try self.arena.create(Resource_File);

            if (is_template) {
                const tokens = try Template.Token.lex(self.arena, source);
                file.* = .{
                    .cache = self,
                    .realpath = realpath,
                    .source = .{ .template = .{
                        .path = realpath,
                        .source = source,
                        .tokens = tokens,
                    }},
                };
            } else {
                file.* = .{
                    .cache = self,
                    .realpath = realpath,
                    .source = .{ .raw = source },
                    .output = source,
                };
            }

            try self.files.put(self.gpa, path_copy, file);
            return file;
        }

        return error.FileNotFound;
    }
};

pub fn compute_output(self: *Resource_File, allocator: std.mem.Allocator) ![]const u8 {
    if (self.output) |output| return output;

    const output = switch (self.source) {
        .raw => |data| try allocator.dupe(u8, data),
        .template => |source| output: {
            var temp = std.ArrayList(u8).init(allocator);
            defer temp.deinit();

            var parser: Template.Parser = .{
                .gpa = allocator,
                .callback_context = self.cache,
                .include_callback = template_include,
                .resource_callback = template_resource,
            };
            defer parser.deinit();

            try parser.append(source);

            var template = try parser.finish(allocator, true);
            defer template.deinit(allocator);

            const writer = temp.writer();
            try template.render(writer.any(), {}, .{ .escape_fn = Template.escape.none });
            const output = try temp.toOwnedSlice();
            var digest: Digest = undefined;
            Hash.hash(output, &digest, .{});
            self.digest = digest;
            break :output output;
        },
    };

    self.output = output;
    return output;
}

pub fn compute_digest(self: *Resource_File, temp: std.mem.Allocator) !Digest {
    if (self.digest) |digest| return digest;

    var hash: Digest = undefined;

    switch (self.source) {
        .raw => |data| {
            Hash.hash(data, &hash, .{});
        },
        .template => |source| {
            var parser: Template.Parser = .{
                .gpa = temp,
                .callback_context = self.cache,
                .include_callback = template_include,
                .resource_callback = template_resource,
            };
            defer parser.deinit();

            try parser.append(source);

            var template = try parser.finish(temp, true);
            defer template.deinit(temp);

            var hasher = Hash.init(.{});
            const writer = hasher.writer();
            try template.render(writer.any(), {}, .{ .escape_fn = Template.escape.none });
            hasher.final(&hash);
        },
    }

    self.digest = hash;
    return hash;
}

pub fn compute_http_path(self: *Resource_File, arena: std.mem.Allocator, temp: std.mem.Allocator) ![]const u8 {
    if (self.http_path) |path| return path;

    const hash = try self.compute_digest(temp);
    const path = try std.fmt.allocPrint(arena, "/{}{s}", .{ std.fmt.fmtSliceHexLower(&hash), std.fs.path.extension(self.realpath) });
    self.http_path = path;
    return path;
}

const empty_source: []const u8 = "";
const empty_tokens: Template.Token.List = .{
    .kinds = &.{ .eof },
    .spans = @as([]const []const u8, &.{ empty_source }).ptr,
};

pub fn template_include(p: *Template.Parser, raw_path: []const u8) anyerror!Template.Source {
    const c: *Cache = @alignCast(@ptrCast(p.callback_context orelse return .{
        .path = "",
        .source = empty_source,
        .tokens = empty_tokens,
    }));

    var full_path = raw_path;
    var path_buf_frag: [std.fs.max_path_bytes + 100]u8 = undefined;
    if (std.mem.startsWith(u8, raw_path, "#")) {
        var base = p.include_stack.getLast().path;
        if (std.mem.indexOfScalar(u8, base, '#')) |frag_start| {
            base = base[0..frag_start];
        }
        full_path = try std.fmt.bufPrint(&path_buf_frag, "{s}{s}", .{ base, raw_path });
    }

    const file = try c.get(full_path);
    return switch (file.source) {
        .template => |source| source,
        else => error.NotATemplate,
    };
}

pub fn template_resource(p: *Template.Parser, raw_path: []const u8) anyerror![]const u8 {
    const c: *Cache = @alignCast(@ptrCast(p.callback_context orelse return ""));
    const file = try c.get(raw_path);
    return try file.compute_http_path(c.arena, c.gpa);
}

const Template = @import("zkittle");
const std = @import("std");
