const std = @import("std");

const zttio = @import("zttio");

const Arg = @import("Arg.zig");
const Tokenizer = @import("Tokenizer.zig");
const TypeArg = @import("TypeArg.zig");

pub const HEADING_STYLING = zttio.Styling{
    .thickness = .bold,
};

pub fn Parser(comptime Config: type) type {
    std.debug.assert(@typeInfo(Config) == .@"struct");
    const info = @typeInfo(Config).@"struct";

    inline for (info.fields) |field| {
        if (field.default_value_ptr == null) {
            @compileError("field '" ++ field.name ++ "' in struct '" ++ @typeName(Config) ++ "' doesn't have a default value");
        }

        switch (field.type) {
            TypeArg.StopOnSeparator,
            TypeArg.Help,
            => continue,
            else => {},
        }

        if (!@hasDecl(field.type, "TYPE_ARG")) {
            @compileError("field '" ++ field.name ++ "' in struct '" ++ @typeName(Config) ++ "' doesn't have the declaration 'TYPE_ARG'");
        }
        if (@TypeOf(@field(field.type, "TYPE_ARG")) != TypeArg) {
            @compileError("'TYPE_ARG' declaration in field '" ++ field.name ++ "' in struct '" ++ @typeName(Config) ++ "' is not of type '" ++ @typeName(TypeArg) ++ "'");
        }
    }

    const options_count, const positional_args_count, const subcommand_count = blk: {
        var options_count = 1; // for help flag
        var positional_args_count = 0;
        var subcommand_count = 0;
        inline for (info.fields) |field| {
            switch (field.type) {
                TypeArg.StopOnSeparator,
                TypeArg.Help,
                => continue,
                else => {},
            }
            const field_arg: TypeArg = @field(field.type, "TYPE_ARG");

            if (field_arg.is_command) {
                std.debug.assert(field_arg.info.name == .long);
                std.debug.assert(field_arg.info.index == null);
                subcommand_count += 1;
                continue;
            }

            if (field_arg.info.name.hasLongName()) {
                options_count += 1;
            }

            if (field_arg.info.index != null) {
                positional_args_count += 1;
            }
        }

        break :blk .{ options_count, positional_args_count, subcommand_count };
    };

    const stop_on_separator: bool, const help: TypeArg.Help, const short_map: [256]?ArgOffset(Config), const options_map: std.StaticStringMap(ArgOffset(Config)), const positional_map: [positional_args_count]?ArgOffset(Config), const subcommand_map: std.StaticStringMap(ArgOffset(Config)) = process: {
        var stop_on_separator: bool = false;
        var help: TypeArg.Help = .{};

        var name_pair_i: usize = 1;
        var options: [options_count]struct { []const u8, ArgOffset(Config) } = undefined;
        options[0] = .{ "help", undefined };

        var short_map: [256]?ArgOffset(Config) = undefined;
        @memset(short_map[0..], null);
        short_map['h'] = undefined;

        var positional_map: [positional_args_count]?ArgOffset(Config) = undefined;
        @memset(positional_map[0..], null);

        var subcommand_i: usize = 0;
        var subcommands: [subcommand_count]struct { []const u8, ArgOffset(Config) } = undefined;

        inline for (info.fields) |field| {
            switch (field.type) {
                TypeArg.StopOnSeparator => {
                    stop_on_separator = true;
                    continue;
                },
                TypeArg.Help => {
                    help = @field(Config{}, field.name);
                    continue;
                },
                else => {},
            }

            const arg_offset = ArgOffset(Config).from(field.name);
            const field_arg: TypeArg = @field(field.type, "TYPE_ARG");
            const field_info = &field_arg.info;

            if (field_arg.is_command) {
                subcommands[subcommand_i] = .{ field_info.name.long, arg_offset };
                subcommand_i += 1;
                continue;
            }

            if (field_info.name.hasLongName()) {
                const name = field_info.name.getLongName();
                for (options[0..name_pair_i]) |pair| {
                    std.debug.assert(!std.mem.eql(u8, pair.@"0", name));
                }
                options[name_pair_i] = .{ name, arg_offset };
                name_pair_i += 1;
            }

            switch (field_info.name) {
                .long => {},
                .short => |short| {
                    std.debug.assert(short_map[short] == null);
                    short_map[short] = arg_offset;
                },
                .both => |both| {
                    std.debug.assert(short_map[both.short] == null);
                    short_map[both.short] = arg_offset;
                },
            }

            if (field_info.index) |index| {
                if (index == 0) {
                    const next_index = blk: {
                        var i = 0;
                        while (positional_map[i] != null) {
                            i += 1;
                        }
                        break :blk i;
                    };
                    std.debug.assert(positional_map[next_index] == null);
                    positional_map[next_index] = arg_offset;
                } else {
                    std.debug.assert(positional_map[index] == null);
                    positional_map[index] = arg_offset;
                }
            }
        }

        break :process .{
            stop_on_separator,
            help,
            short_map,
            std.StaticStringMap(ArgOffset(Config)).initComptime(options),
            positional_map,
            std.StaticStringMap(ArgOffset(Config)).initComptime(subcommands),
        };
    };

    return struct {
        const Self = @This();

        tokenizer: *Tokenizer,
        positional_arg_count: usize = 0,

        writer: *std.Io.Writer,

        pub fn init(tokenizer: *Tokenizer, writer: *std.Io.Writer) Self {
            return Self{
                .tokenizer = tokenizer,

                .writer = writer,
            };
        }

        const InternalParseError = TypeArg.ArgParseError || error{HelpFlagFound};

        fn internalParse(self: *Self, result: *Config) InternalParseError!void {
            // @TODO: check for required arguments

            const ctx: TypeArg.ParseContext = .{
                .tokenizer = self.tokenizer,

                .writer = self.writer,
            };

            while (self.tokenizer.peek()) |token| {
                switch (token) {
                    .separator => {
                        self.tokenizer.toss();
                        if (stop_on_separator) {
                            return;
                        }
                    },
                    .short_option => |opt| {
                        if (opt.name == 'h') {
                            self.tokenizer.toss();
                            return InternalParseError.HelpFlagFound;
                        }

                        const arg_offset = short_map[opt.name] orelse
                            return InternalParseError.ParseFailed;
                        try arg_offset.parse(result, &ctx);
                    },
                    .option => |opt| {
                        if (std.mem.eql(u8, opt.name, "help")) {
                            self.tokenizer.toss();
                            return InternalParseError.HelpFlagFound;
                        }

                        const arg_offset = options_map.get(opt.name) orelse
                            return InternalParseError.ParseFailed;
                        try arg_offset.parse(result, &ctx);
                    },
                    .arg => |arg| {
                        if (comptime positional_map.len != 0) {
                            if (positional_map[self.positional_arg_count]) |arg_offset| {
                                try arg_offset.parse(result, &ctx);
                                continue;
                            }
                        }

                        const arg_offset = subcommand_map.get(arg) orelse
                            return InternalParseError.ParseFailed;
                        try arg_offset.parse(result, &ctx);
                        break;
                    },
                }
            }
        }

        pub fn parse(self: *Self) TypeArg.ArgParseError!?Config {
            var result: Config = .{};

            if (comptime help.on_empty_args) {
                if (self.tokenizer.peek() == null) {
                    try self.writeHelpScreen(false);
                    return null;
                }
            }

            self.internalParse(&result) catch |err| switch (err) {
                InternalParseError.ParseAborted => return TypeArg.ArgParseError.ParseAborted,
                InternalParseError.ParseFailed => {
                    if (comptime help.on_parse_error) {
                        try self.writeHelpScreen(false);
                        return TypeArg.ArgParseError.ParseAborted;
                    }
                    return TypeArg.ArgParseError.ParseFailed;
                },
                InternalParseError.HelpFlagFound => {
                    try self.writeHelpScreen(true);
                    return TypeArg.ArgParseError.ParseAborted;
                },
                InternalParseError.WriteFailed => {
                    return TypeArg.ArgParseError.WriteFailed;
                },
            };

            return result;
        }

        fn writeHelpScreen(self: *Self, help_flag_found: bool) std.Io.Writer.Error!void {
            try self.writer.writeAll("usage:");
            const last_arg = blk: {
                var i = self.tokenizer.index;
                if (i == 0) {
                    break :blk 0;
                }
                if (self.tokenizer.next_token) |_| {
                    i -= 1;
                }
                if (help_flag_found) {
                    i -|= 1;
                }
                break :blk i;
            };
            for (self.tokenizer.args[0..last_arg]) |arg| {
                try self.writer.writeByte(' ');
                try self.writer.writeAll(arg);
            }
            if (options_count > 0) {
                try self.writer.writeAll(" [options]");
            }
            if (subcommand_count > 0) {
                try self.writer.writeAll(" <command>");
            }
            try self.writer.writeAll("\n\n");

            if (comptime subcommand_count > 0) {
                try HEADING_STYLING.print(self.writer);
                try self.writer.writeAll("commands:\n" ++ zttio.Styling.reset);
                inline for (info.fields) |field| {
                    switch (field.type) {
                        TypeArg.StopOnSeparator,
                        TypeArg.Help,
                        => continue,
                        else => {},
                    }

                    const field_arg: TypeArg = @field(field.type, "TYPE_ARG");
                    const field_info = &field_arg.info;

                    if (!field_arg.is_command) {
                        continue;
                    }

                    try self.writer.writeAll("  ");
                    try Arg.NAME_STYLING.print(self.writer);
                    try self.writer.writeAll(field_info.name.long);
                    try self.writer.writeByte('\n');

                    if (field_info.description) |desc| {
                        var iter = std.mem.splitScalar(u8, desc, '\n');
                        while (iter.next()) |chunk| {
                            try self.writer.writeAll("      ");
                            try Arg.DESCRIPTION_STYLING.format(self.writer);
                            try self.writer.writeAll(chunk);
                            try self.writer.writeByte('\n');
                            try self.writer.writeAll(zttio.Styling.reset);
                        }
                    }

                    try self.writer.writeByte('\n');
                    try self.writer.writeAll(zttio.Styling.reset);
                }
            }

            if (comptime options_count > 0) {
                try HEADING_STYLING.print(self.writer);
                try self.writer.writeAll("options:\n" ++ zttio.Styling.reset);
                inline for (info.fields) |field| {
                    switch (field.type) {
                        TypeArg.StopOnSeparator,
                        TypeArg.Help,
                        => continue,
                        else => {},
                    }

                    const field_arg: TypeArg = @field(field.type, "TYPE_ARG");
                    const field_info = &field_arg.info;

                    if (field_arg.is_command or field_info.index != null) {
                        continue;
                    }

                    try field_info.printHelpText(self.writer);
                }
            }

            const help_arg = Arg{
                .name = .{ .both = .{
                    .short = 'h',
                    .long = "help",
                } },
                .description = "print help and exit",
            };
            try help_arg.printHelpText(self.writer);

            try self.writer.flush();
        }
    };
}

fn ArgOffset(comptime Config: type) type {
    return struct {
        const Self = @This();

        offset: usize,
        arg: *const TypeArg,

        pub fn from(comptime field_name: []const u8) Self {
            return Self{
                .offset = @offsetOf(Config, field_name),
                .arg = &@field(@FieldType(Config, field_name), "TYPE_ARG"),
            };
        }

        pub fn parse(self: *const Self, config_ptr: *Config, ctx: *const TypeArg.ParseContext) TypeArg.ArgParseError!void {
            const ptr: *anyopaque = @ptrFromInt(@intFromPtr(config_ptr) + self.offset);
            return self.arg.vtable.parse(ptr, ctx);
        }
    };
}
