const std = @import("std");

const Arg = @import("Arg.zig");
const Tokenizer = @import("Tokenizer.zig");
const TypeParser = @import("type_parser.zig").Parser;

pub const ArgParseError = std.Io.Writer.Error || error{ ParseFailed, ParseAborted };

const TypeArg = @This();

info: Arg,
is_command: bool = false,

vtable: *const VTable,

pub const VTable = struct {
    parse: *const fn (ptr: *anyopaque, ctx: *const ParseContext) ArgParseError!void,
};

pub const ParseContext = struct {
    tokenizer: *Tokenizer,

    writer: *std.Io.Writer,
};

pub const StopOnSeparator = struct {};
pub const Help = struct {
    on_empty_args: bool = false,
    on_parse_error: bool = true,
};

pub const CommandConfig = struct {
    name: []const u8,
    description: ?[]const u8,
};

pub fn Command(comptime config: CommandConfig, comptime Args: type) type {
    return struct {
        pub const TYPE_ARG = TypeArg{
            .info = .positional(config.name, config.description, null, .not_required),
            .is_command = true,
            .vtable = &.{
                .parse = parse,
            },
        };

        const Self = @This();

        used: bool = false,
        args: Args = if (Args == void) void{} else .{},

        fn parse(ptr: *anyopaque, ctx: *const ParseContext) ArgParseError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.used = true;

            ctx.tokenizer.toss();

            var parser = TypeParser(if (Args != void) Args else struct {}).init(ctx.tokenizer, ctx.writer);
            if (Args != void) {
                self.args = try parser.parse() orelse return error.ParseFailed;
            } else {
                _ = try parser.parse() orelse return error.ParseAborted;
            }
        }
    };
}

pub const FlagConfig = struct {
    name: Arg.Name,
    description: ?[]const u8 = null,
};

pub fn Flag(comptime config: FlagConfig) type {
    return struct {
        pub const TYPE_ARG = TypeArg{
            .info = .flag(config.name, config.description),
            .vtable = &.{
                .parse = parse,
            },
        };

        const Self = @This();

        set: bool = false,
        count: u32 = 0,

        fn parse(ptr: *anyopaque, ctx: *const ParseContext) ArgParseError!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.set = true;
            self.count += 1;

            ctx.tokenizer.toss();
        }
    };
}
