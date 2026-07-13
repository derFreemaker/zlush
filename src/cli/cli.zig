const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
const TypeArg = @import("TypeArg.zig");
pub const Help = TypeArg.Help;
pub const StopOnSeparator = TypeArg.StopOnSeparator;
pub const Command = TypeArg.Command;
pub const Flag = TypeArg.Flag;
pub const TypeParser = @import("type_parser.zig").Parser;

pub fn parseArgs(comptime Root: type, writer: *std.Io.Writer, args: []const []const u8) TypeArg.ArgParseError!?Root {
    var tokenizer = Tokenizer.init(args);
    tokenizer.index += 1;

    var parser: TypeParser(Root) = .init(&tokenizer, writer);
    return parser.parse();
}
