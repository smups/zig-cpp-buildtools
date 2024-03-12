const std = @import("std");
const zstr = @import("zstr");

const Allocator = std.mem.Allocator;

pub const ReplaceError = error {
    NoReplacement
};

/// Reads file located at `input_path` and replaces all occurences of matching strings with their
/// corresponding targets, as defined by the `dict` paramter. `input_file` and `output_file` may
/// point to the same file. The `dict` paramter works as follows: passing `.{ .yeet = "skeet" }`
/// will replace `yeet` with `skeet`. There is no limit to the number of paramters passed in this
/// way using `dict`.
pub fn replaceAllUnmanaged(
    dict: anytype,
    alloc: Allocator,
    buffer: *std.ArrayList(u8),
    input_file: std.fs.File,
    output_file: std.fs.File
) !usize {
    // Clear buffer
    buffer.items.len = 0;

    // Read file
    try input_file.reader().readAllArrayList(buffer, std.math.maxInt(usize));

    // Turn buffer into string
    var str = try zstr.fromConstBytes(alloc, buffer.items);
    defer str.deinit();

    // Replace all matching entries in buffer
    var n_reps: usize = 0;
    inline for (std.meta.fields(@TypeOf(dict))) |field| {
        const replacement = @field(dict, field.name) orelse {
            return ReplaceError.NoReplacement;
        };
        n_reps += try str.replace(field.name, replacement);
    }

    //Write modifed file to output - block untill disk operations are DONE!
    try output_file.writeAll(str.bytes());
    try output_file.sync();

    return n_reps;
}

test replaceAllUnmanaged {
    // Set-up test files
    const tmp_dir = std.testing.tmpDir(.{});
    var fin_new = try tmp_dir.dir.createFile("in.test", .{});
    fin_new.close();
    const fin = try tmp_dir.dir.openFile("in.test", .{});
    var fout = try tmp_dir.dir.createFile("out.test", .{});

    // set-up allocator & buffer
    var alloc = std.testing.allocator_instance.allocator();
    var buf = std.ArrayList(u8).init(alloc);

    // First try out a combination that should work
    const dict = struct { test_f1: ?[]const u8 }{ .test_f1 = "test" };
    _ = try replaceAllUnmanaged(dict, alloc, &buf, fin, fout);
}

/// See `replace_all_unmanaged`
pub fn replaceAll(
    dict: anytype,
    alloc: Allocator,
    input_file: std.fs.File,
    output_file: std.fs.File
) !usize {
    var buffer = std.ArrayList(u8).init(alloc);
    defer buffer.deinit();
    return try replaceAllUnmanaged(dict, alloc, &buffer, input_file, output_file);
}

test replaceAll {
    // Set-up test files
    const tmp_dir = std.testing.tmpDir(.{});
    var fin_new = try tmp_dir.dir.createFile("in.test", .{});
    fin_new.close();
    const fin = try tmp_dir.dir.openFile("in.test", .{});
    var fout = try tmp_dir.dir.createFile("out.test", .{});

    // set-up allocator & buffer
    var alloc = std.testing.allocator_instance.allocator();

    // First try out a combination that should work
    const dict = struct { test_f1: ?[]const u8 }{ .test_f1 = "test" };
    _ = try replaceAll(dict, alloc, fin, fout);
}

/// Iterate (recusively) over all elements in `input_dir` and pass them to `replace_all`. Returns
/// number of replaced files.
pub fn replaceAllInDir(
    dict: anytype,
    alloc: Allocator,
    input_dir: std.fs.Dir,
    output_dir: std.fs.Dir,
) !usize {
    // Re-use the same buffer
    var buffer = std.ArrayList(u8).init(alloc);
    defer buffer.deinit();
    var n_touched: usize = 0;

    // Iterate over input dir
    var input_iter = try input_dir.openIterableDir(".", .{});
    var walker = try input_iter.walk(alloc);
    defer walker.deinit();
    
    while (try walker.next()) |entry| {
        // Handle creating directories
        if (entry.kind == std.fs.File.Kind.directory) {
            try output_dir.makePath(entry.path);
            continue;
        }
        n_touched += 1;

        // Open file for reading
        const input_file = try input_dir.openFile(entry.path, .{});

        // Create output file if it does not exist
        const output_file = try output_dir.createFile(entry.path, .{});

        //Run our replacement procedure
        _ = try replaceAllUnmanaged(dict, alloc, &buffer, input_file, output_file);
    }

    return n_touched;
}

test replaceAllInDir {
    const tmp_dir = std.testing.tmpDir(.{}).dir;
    try tmp_dir.makeDir("in");
    try tmp_dir.makeDir("out");
    const in_dir = try tmp_dir.openDir("in", .{});
    const out_dir = try tmp_dir.openDir("out", .{});

    const test_dict = struct { ohno: ?[]const u8 }{ .ohno = "allgood" };
    var alloc = std.testing.allocator_instance.allocator();

    // try empty directories
    _ = try replaceAllInDir(test_dict, alloc, in_dir, out_dir);

    // Add some files to directories
    _ = try in_dir.createFile("test1.test", .{});
    _ = try in_dir.createFile("test2.test", .{});
    _ = try replaceAllInDir(test_dict, alloc, in_dir, out_dir);
    
    // Add a subdirectory
    try in_dir.makeDir("subdir");
    _ = try replaceAllInDir(test_dict, alloc, in_dir, out_dir);
}

pub fn Arguments(comptime Dict: type, comptime command: []const u8) type {
    // Verify that `Dict` is a struct and has fields of type ?[]const u8
    inline for (std.meta.fields(Dict)) |field| {
        if (field.type != ?[]const u8) {
            @compileError("Dict type must be a struct where all fields have type ?[]const u8");
        }
    }

    return struct {
        in_path: []const u8,
        out_path: []const u8,
        dictionary: Dict,

        pub const ParseError = error {
            MissingDirs,
            InvalidArgument,
            MalformedReplacementDirective,
            MissingReplacementDirective,
            UnknownReplacementTarget
        };

        pub const command_usage = generateUsage();

        pub fn parseArgs(args: []const [:0]const u8) !@This() {
            // These are all just pointers to args
            var out_path: ?[]const u8 = null;
            var in_path: ?[]const u8 = null;
            var dictionary: Dict = undefined;
            zeroDictionary(&dictionary);

            if (args.len < 3) {
                return ParseError.MissingDirs;
            }

            var i: usize = 1; //0 is the command itself
            while (i < args.len) : (i += 1) {
                const current_arg = args[i];
                const eql = std.mem.eql;

                // Check for help argument
                if (eql(u8, "-h", current_arg) or eql(u8, "-help", current_arg)) {
                    try std.io.getStdOut().writeAll(command_usage);
                    std.process.exit(0);
                }

                // First argument is the input folder
                if (i == 1) {
                    in_path = current_arg;
                    continue;
                    // Second argument is the output folder
                } else if (i == 2) {
                    out_path = current_arg;
                    continue;
                } else if (!eql(u8, "-r", current_arg)) {
                    return ParseError.InvalidArgument;
                }

                // All other arguments are replacement directives
                if (args.len <= i + 2) {
                    return ParseError.MalformedReplacementDirective;
                }

                // skip over this argument next iteration
                i += 1;
                var target: []const u8 = args[i];
                i += 1;
                var replacement: []const u8 = args[i];

                // Verify that TARGET is actually supposed to be replaced and construct dictionary
                inline for (std.meta.fields(Dict)) |field| {
                    if (std.mem.eql(u8, target, field.name)) {
                        @field(dictionary, field.name) = replacement;
                        break;
                    }
                } else {
                    return ParseError.UnknownReplacementTarget;
                }
            }

            // We have looped through all arguments, dictionary should be completely initialised
            inline for (std.meta.fields(Dict)) |field| {
                if (@field(dictionary, field.name) == null) {
                    return ParseError.MissingReplacementDirective;
                }
            }

            return .{
                .in_path = in_path orelse unreachable,
                .out_path = out_path orelse unreachable,
                .dictionary = dictionary,
            };
        }

        fn zeroDictionary(dict: *Dict) void {
            inline for (std.meta.fields(Dict)) |field| {
                @field(dict, field.name) = null;
            }
        }

        fn generateUsage() []const u8 {
            comptime {
                var usage: []const u8 =
                    "Usage: "
                    ++ command
                    ++ " [input_path] [output_path] [replacement directives]\n\n"
                    ++
                    \\Arguments:
                    \\    [input_path]: path to input source file.
                    \\    [output_path]: path to write modified source file to.
                    \\    [replacement directives]: sequence of arguments with the following format:
                    \\        -r TARGET REPLACEMENT
                    \\    Each TARGET string found in the original source file will be replaced by
                    \\    its corresponding REPLACEMENT string. Note that all targets MUST have a
                    \\    replacement specified. For a list of possible targets, see down below.
                    \\
                    \\Targets:
                    \\
                ;

                inline for (std.meta.fieldNames(Dict)) |target_name| {
                    usage = usage ++ "    " ++ target_name ++ "\n";
                }

                return usage;
            }
        }
    }; // return struct { ... }; <- do not remove semicolon
}

test "empty" {
    const EmptyDict = struct {};
    const cmd = "cmd";
    const args = [_][:0]const u8 {
        cmd, "infile.test", "outfile.test"
    };

    const parsed_args = try Arguments(EmptyDict, cmd).parseArgs(&args);

    // Assertions
    try std.testing.expectEqualStrings(args[1], parsed_args.in_path);
    try std.testing.expectEqualStrings(args[2], parsed_args.out_path);
}

test "basic" {
    const TestDict = struct { tf1: ?[]const u8 };
    const cmd = "cmd";
    const args = [_][:0]const u8 {
        cmd, "infile.test", "outfile.test",
        "-r", "tf1", "replaced1"
    };

    const parsed_args = try Arguments(TestDict, cmd).parseArgs(&args);

    // Assertions
    try std.testing.expectEqualStrings(args[1], parsed_args.in_path);
    try std.testing.expectEqualStrings(args[2], parsed_args.out_path);
    try std.testing.expectEqualStrings("replaced1", parsed_args.dictionary.tf1.?);
}

test "integration" {
    const alloc = std.testing.allocator_instance.allocator();
    const tmp = std.testing.tmpDir(.{}).dir;
    const in_dir = try tmp.makeOpenPath("in", .{});
    const out_dir = try tmp.makeOpenPath("out", .{});
    const test_file = try in_dir.createFile("t.test", .{});
    try test_file.writeAll("tf1");
    test_file.close();

    // Get absolute paths
    const in_path = try in_dir.realpathAlloc(alloc, ".");
    const out_path = try out_dir.realpathAlloc(alloc, ".");
    const in_path_z = try alloc.dupeZ(u8, in_path);
    const out_path_z = try alloc.dupeZ(u8, out_path);
    alloc.free(in_path);
    alloc.free(out_path);
    defer alloc.free(in_path_z);
    defer alloc.free(out_path_z);
    
    // Parse args + replace all in dir
    const TestDict = struct { tf1: ?[]const u8 };
    const cmd = "cmd";
    const args = [_][:0]const u8 {
        cmd, in_path_z, out_path_z,
        "-r", "tf1", "replaced1"
    };
    const parsed_args = try Arguments(TestDict, cmd).parseArgs(&args);
    try std.testing.expectEqualStrings("replaced1", parsed_args.dictionary.tf1.?);
    _ = try replaceAllInDir(parsed_args.dictionary, alloc, in_dir, out_dir);

    // Check the output
    const test_file_out = try out_dir.openFile("t.test", .{});
    const out = try test_file_out.readToEndAlloc(alloc, 100);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("replaced1", out);
}
