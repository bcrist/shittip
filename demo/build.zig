const std = @import("std");
const shittip = @import("shittip");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "demo",
        .root_source_file = b.path("demo.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    exe.root_module.addImport("http", b.dependency("shittip", .{}).module("http"));
    exe.root_module.addImport("resources", shittip.resources(b, &.{
        .{ .path = "resources" },
    }, .{}));
    b.installArtifact(exe);

    var run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "run demo server").dependOn(&run.step);
}
