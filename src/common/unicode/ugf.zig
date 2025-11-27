const std = @import("std");

pub const UGFUnit = struct {
    data: UGFUnitData,
    dw: u7,

    pub inline fn initSingle(cp: u21, dw: u7) UGFUnit {
        const data = UGFUnitData{ .single = cp };

        return UGFUnit{
            .data = data,
            .dw = dw,
        };
    }

    pub fn init(allocator: std.mem.Allocator, codepoints: []const u21, dw: u7) error{ OutOfMemory, TooManyCodepoints }!UGFUnit {
        if (codepoints.len > std.math.maxInt(u13)) {
            return error.TooManyCodepoints;
        }

        const codepoints_copy = try allocator.dupe(u21, codepoints);

        const data = UGFUnitData{ .multiple = .{
            .codepoints = codepoints_copy.ptr,
            .len = @intCast(codepoints.len),
        } };

        return UGFUnit{
            .data = data,
            .dw = dw,
        };
    }

    pub fn initBuf(codepoints: []const u21, dw: u7) error{TooManyCodepoints}!UGFUnit {
        if (codepoints.len > std.math.maxInt(u13)) {
            return error.TooManyCodepoints;
        }

        const data = UGFUnitData{ .multiple = .{
            .codepoints = codepoints.ptr,
            .len = @intCast(codepoints.len),
        } };

        return UGFUnit{
            .data = data,
            .dw = dw,
        };
    }

    pub fn deinit(self: *UGFUnit, allocator: std.mem.Allocator) void {
        allocator.free(self.slice());
    }

    pub inline fn slice(self: *const UGFUnit) []const u21 {
        return self.data.slice();
    }

    pub const UGFUnitData = union(enum) {
        single: u21,
        multiple: UGFUnitDataMultiple,

        pub fn deinit(self: *UGFUnitData, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .single => {},
                .multiple => |m| {
                    allocator.free(m.slice());
                },
            }
        }

        pub inline fn slice(self: *const UGFUnitData) []const u21 {
            switch (self.*) {
                .single => |*s| {
                    return @as([*]const u21, @ptrCast(s))[0..1];
                },
                .multiple => |m| {
                    return m.slice();
                },
            }
        }

        pub const UGFUnitDataMultiple = struct {
            codepoints: [*]const u21,
            len: u13,

            pub inline fn slice(self: *const UGFUnitDataMultiple) []const u21 {
                return self.codepoints[0 .. self.len + 1];
            }
        };
    };
};
