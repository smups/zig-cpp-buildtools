const std = @import("std");
const zstr = @import("zigstr");

const Allocator = std.mem.Allocator;

/// Reads file located at `input_path` and replaces all occurences of matching strings with their
/// corresponding targets, as defined by the `dict` paramter. `input_file` and `output_file` may
/// point to the same file. The `dict` paramter works as follows: passing `.{ .yeet = "skeet" }`
/// will replace `yeet` with `skeet`. There is no limit to the number of paramters passed in this
/// way using `dict`. 
pub fn replace_all_unmanaged(
    comptime dict: anytype,
    alloc: Allocator,
    buffer: *std.ArrayList(u8),
    input_file: std.fs.File,
    output_file: std.fs.File
) !void {    
    // Clear buffer
    buffer.items = [0]u8;
    
    // Read file
    try input_file.reader().readAllArrayList(buffer, std.math.maxInt(usize));
    input_file.close();

    // Turn buffer into string
    var zig_str = try zstr.fromConstBytes(alloc, buffer.items);

    // Replace all matching entries in buffer
    inline for (std.meta.fields(dict)) |field| {
        try zig_str.replace(field, @field(dict, field));
    }

    //Write shit to file
    try output_file.writer().writeAll(buffer.items);
    output_file.close();
}

/// See `replace_all_unmanaged`
pub fn replace_all(
    comptime dict: anytype,
    alloc: Allocator,
    input_file: std.fs.File,
    output_file: std.fs.File
) !void {
    var buffer = std.ArrayList(u8).init();
    try replace_all_unmanaged(dict, alloc, &buffer, input_file, output_file);
}

/// Iterate (recusively) over all elements in `input_dir` and pass them to `replace_all`.
pub fn replace_all_in_dir(
    comptime dict: anytype,
    alloc: Allocator,
    input_dir: std.fs.Dir,
    output_dir: std.fs.Dir,
) !void {
    // Re-use the same buffer
    var buffer = std.ArrayList(u8).init();
    
    // Iterate over input dir
    var input_iter = try input_dir.openIterableDir(".", .{});
    var walker = try input_iter.walk(alloc);
    while (try walker.next()) |entry| {
        // Open file for reading
        const input_file = input_dir.openFile(entry.path, .{});

        // Create output file if it does not exist
        const output_file = output_dir.createFile(entry.path, .{});

        //Run our replacement procedure
        try replace_all_unmanaged(dict, alloc, &buffer, input_file, output_file);
    }
}
