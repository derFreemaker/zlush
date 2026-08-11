const std = @import("std");
const builtin = @import("builtin");

pub fn IndexT(comptime ParentT: type, comptime T: type) type {
    // we only need the parent type for uniques
    _ = ParentT;

    if (@typeInfo(T) != .int) {
        @compileError("expected T is of type 'int'");
    }

    return enum(T) {
        pub const UnderlyingT = T;

        const Self = @This();

        _,

        pub fn fromAny(v: anytype) error{Overflow}!Self {
            const info = @typeInfo(@TypeOf(v));
            if (info != .int) {
                @compileError("expected type 'int'");
            }

            if (v < 0 or v > std.math.maxInt(UnderlyingT)) {
                return error.Overflow;
            }
            return switch (info) {
                .int => @enumFromInt(v),
                else => unreachable,
            };
        }

        pub inline fn from(v: T) Self {
            return @enumFromInt(v);
        }

        pub inline fn value(self: Self) T {
            return @intFromEnum(self);
        }

        pub inline fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{d}", .{self.value()});
        }
    };
}

pub fn OptIndexT(comptime ParentT: type, comptime T: type) type {
    if (@typeInfo(T) != .int) {
        @compileError("expected T is of type 'int'");
    }

    return enum(T) {
        pub const UnderlyingT = T;

        const Index = IndexT(ParentT, T);

        const Self = @This();

        invalid = 0,
        _,

        pub fn fromAny(v: anytype) error{Overflow}!Self {
            const info = @typeInfo(@TypeOf(v));
            if (info != .int) {
                @compileError("expected type 'int'");
            }

            if (v < 0 or v > std.math.maxInt(UnderlyingT)) {
                return error.Overflow;
            }
            return switch (info) {
                .int => @enumFromInt(v),
                else => unreachable,
            };
        }

        pub inline fn from(idx: Index) Self {
            return @enumFromInt(@intFromEnum(idx));
        }

        pub inline fn fromValue(v: T) Self {
            return @enumFromInt(v);
        }

        pub inline fn isInvalid(self: Self) bool {
            return @intFromEnum(self) == 0;
        }

        pub inline fn maybeValid(self: Self) ?Index {
            return if (self.isInvalid()) null else @as(Index, @enumFromInt(@intFromEnum(self)));
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const idx = self.maybeValid() orelse {
                try writer.writeAll("<invalid>");
                return;
            };
            try idx.format(writer);
        }
    };
}
