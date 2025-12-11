const std = @import("std");

const UGF8 = @import("ugf8.zig");

pub const Unit = struct {
    data: UnitData,
    dw: u7,

    pub inline fn initSingle(cp: u21, dw: u7) Unit {
        const data = UnitData{ .single = cp };

        return Unit{
            .data = data,
            .dw = dw,
        };
    }

    pub fn init(allocator: std.mem.Allocator, codepoints: []const u21, dw: u7) error{ OutOfMemory, NotEnoughCodepoints, TooManyCodepoints }!Unit {
        if (codepoints.len == 0) {
            return error.NotEnoughCodepoints;
        }
        if (codepoints.len > std.math.maxInt(u13)) {
            return error.TooManyCodepoints;
        }

        const codepoints_copy = try allocator.dupe(u21, codepoints);

        const data = UnitData{ .multiple = .{
            .codepoints = codepoints_copy.ptr,
            .len = @intCast(codepoints.len - 1),
        } };

        return Unit{
            .data = data,
            .dw = dw,
        };
    }

    pub fn initBuf(codepoints: []const u21, dw: u7) error{ NotEnoughCodepoints, TooManyCodepoints }!Unit {
        if (codepoints.len == 0) {
            return error.NotEnoughCodepoints;
        }
        if (codepoints.len > std.math.maxInt(u13)) {
            return error.TooManyCodepoints;
        }

        const data = UnitData{ .multiple = .{
            .codepoints = codepoints.ptr,
            .len = @intCast(codepoints.len - 1),
        } };

        return Unit{
            .data = data,
            .dw = dw,
        };
    }

    pub fn deinit(self: *Unit, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }

    pub inline fn len(self: *const Unit) u13 {
        return self.data.len();
    }

    pub inline fn slice(self: *const Unit) []const u21 {
        return self.data.slice();
    }

    pub fn lenUTF8(self: *const Unit) usize {
        var utf8_len: usize = 0;
        for (self.slice()) |cp| {
            utf8_len += std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        }
        return utf8_len;
    }

    pub fn toUGF8(self: *const Unit, buf: []u8) UGF8.Unit {
        var i: usize = 0;
        for (self.slice()) |cp| {
            i += std.unicode.utf8Encode(cp, buf[i..]) catch unreachable;
        }
        
        return UGF8.Unit{
            .data = buf[0..i],
            .codepoints_count = self.len(),
            .dw = self.dw,
        };
    }

    pub const UnitData = union(enum) {
        single: u21,
        multiple: Multiple,

        pub fn deinit(self: *UnitData, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .single => {},
                .multiple => |m| {
                    allocator.free(m.slice());
                },
            }
        }

        pub inline fn len(self: *const UnitData) u13 {
            return switch (self.*) {
                .single => 1,
                .multiple => |m| m.len + 1,
            };
        }

        pub inline fn slice(self: *const UnitData) []const u21 {
            return switch (self.*) {
                .single => |*s| @as([*]const u21, @ptrCast(s))[0..1],
                .multiple => |m| m.slice(),
            };
        }

        pub const Multiple = struct {
            codepoints: [*]const u21,
            len: u13,

            pub inline fn slice(self: *const Multiple) []const u21 {
                return self.codepoints[0 .. self.len + 1];
            }
        };
    };
};
