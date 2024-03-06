const std = @import("std");
const Allocator = std.mem.Allocator;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Initialise allocator
    // var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena_state.deinit();
    // const alloc = arena_state.allocator();

    // Get optimize and target funcs from user 
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Load zig dependencies
    const zigstr = b.dependency("zigstr", .{
        .target = target,
        .optimize = optimize,
    });

    // Export this project as a module called zig-cpp-buildtools
    _ = b.addModule("zig-cpp-buildtools", .{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &.{
            .{ .name = "zigstr", .module = zigstr.module("zigstr") }
        }
    });
}
