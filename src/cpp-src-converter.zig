const std = @import("std");
const zstr = @import("zstr");

const Allocator = std.mem.Allocator;

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
) !void {    
    // Clear buffer
    buffer.items = [0]u8;
    
    // Read file
    try input_file.reader().readAllArrayList(buffer, std.math.maxInt(usize));
    input_file.close();

    // Turn buffer into string
    var zig_str = try zstr.fromConstBytes(alloc, buffer.items);

    // Replace all matching entries in buffer
    inline for (std.meta.fields(@TypeOf(dict))) |field| {
        try zig_str.replace(field, @field(dict, field));
    }

    //Write shit to file
    try output_file.writer().writeAll(buffer.items);
    output_file.close();
}

/// See `replace_all_unmanaged`
pub fn replaceAll(
    dict: anytype,
    alloc: Allocator,
    input_file: std.fs.File,
    output_file: std.fs.File
) !void {
    var buffer = std.ArrayList(u8).init();
    try replaceAllUnmanaged(dict, alloc, &buffer, input_file, output_file);
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
    var n_replaced: usize = 0;
    
    // Iterate over input dir
    var input_iter = try input_dir.openIterableDir(".", .{});
    var walker = try input_iter.walk(alloc);
    while (try walker.next()) |entry| {
        // Open file for reading
        const input_file = input_dir.openFile(entry.path, .{});

        // Create output file if it does not exist
        output_dir.makePath(entry.dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err
        };
        const output_file = output_dir.createFile(entry.path, .{});

        //Run our replacement procedure
        try replaceAllUnmanaged(dict, alloc, &buffer, input_file, output_file);

        n_replaced += 1;
    }
    
    return n_replaced;
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
        _raw_args: []const [:0]u8,
        _alloc: Allocator,

        pub const ParseError = error {
            MissingDirs,
            InvalidArgument,
            MalformedReplacementDirective,
            MissingReplacementDirective,
            UnknownReplacementTarget  
        };

        pub const command_usage = generateUsage();

        pub fn parseArgsAlloc(alloc: Allocator) !@This() {
            // Allocate arguments.
            const args = try std.process.argsAlloc(alloc);

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
                ._raw_args = args,
                ._alloc = alloc
            };
        }
        
        pub fn deinit(self: @This()) void {
            std.process.argsFree(self._alloc, self._args);
        }
        
        fn zeroDictionary(dict: *Dict) void {
            inline for (std.meta.fields(Dict)) |field| {
                @field(dict, field.name) = null;
            }
        }

        fn generateUsage() []const u8 {
            comptime {
                var usage: []const u8 = "Usage: "
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

