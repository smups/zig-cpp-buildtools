const std = @import("std");
const zstr = @import("zigstr");

const Allocator = std.mem.Allocator;

/// Reads file located at `input_path` and replaces all occurences of matching strings with their
/// corresponding targets, as defined by the `dict` paramter. `input_file` and `output_file` may
/// point to the same file. The `dict` paramter works as follows: passing `.{ .yeet = "skeet" }`
/// will replace `yeet` with `skeet`. There is no limit to the number of paramters passed in this
/// way using `dict`. 
pub fn replace_all(
    comptime dict: anytype,
    alloc: Allocator,
    buffer: *std.ArrayList(u8),
    input_file: std.fs.File,
    output_file: std.fs.File
) !void {    
    // Read file
    try input_file.reader().readAllArrayList(buffer, std.math.maxInt(usize));

    // Turn buffer into string
    var zig_str = try zstr.fromConstBytes(alloc, buffer.items);

    // Replace all matching entries in buffer
    inline for (std.meta.fields(dict)) |field| {
        try zig_str.replace(field, @field(dict, field));
    }

    //Write shit to file
    try output_file.writer().writeAll(buffer.items);
}
