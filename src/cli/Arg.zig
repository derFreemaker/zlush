const std = @import("std");

const zttio = @import("zttio");

pub const DEFAULT_VALUES_DELIMITER = ",";

pub const NAME_STYLING = zttio.Styling{ .fg = .{ .c8 = .bright_yellow } };
pub const DESCRIPTION_STYLING = zttio.Styling{};

const Arg = @This();

name: Name,
description: ?[]const u8 = null,

/// `0` gets interpreted as doesn't take any values
min_values: usize = 0,
/// `0` gets interpreted as takes `inf` values
///
/// if `min_values != 0` otherwise gets ignored
max_values: usize = 0,

values_placeholder: ?[]const []const u8 = null,
valid_values: ?[]const []const u8 = null,
values_delimiter: ?[]const u8 = null,

/// index 0 will be seen as smallest available index
index: ?usize = null,
required: Required = .not_required,

pub fn printHelpText(self: *const Arg, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("  ");
    try NAME_STYLING.print(writer);

    switch (self.name) {
        .short => |short| {
            try writer.writeByte('-');
            try writer.writeByte(short);
        },
        .long => |long| {
            try writer.writeAll("--");
            try writer.writeAll(long);
        },
        .both => |both| {
            try writer.writeAll("--");
            try writer.writeAll(both.long);
            try writer.writeAll(", -");
            try writer.writeByte(both.short);
        },
    }

    try writer.writeAll(zttio.Styling.reset);

    // @TODO: print more helpfull usage patterns

    try writer.writeByte('\n');

    if (self.description) |desc| {
        var iter = std.mem.splitScalar(u8, desc, '\n');
        while (iter.next()) |chunk| {
            try writer.writeAll("      ");
            try DESCRIPTION_STYLING.format(writer);
            try writer.writeAll(chunk);
            try writer.writeByte('\n');
            try writer.writeAll(zttio.Styling.reset);
        }
    }

    try writer.writeByte('\n');
    try writer.writeAll(zttio.Styling.reset);
}

pub fn flag(name: Name, description: ?[]const u8) Arg {
    return Arg{
        .name = name,
        .description = description,
    };
}

/// requires one value
pub fn option(name: Name, description: ?[]const u8) Arg {
    return Arg{
        .name = name,
        .description = description,

        .min_values = 1,
        .max_values = 1,
    };
}

/// takes multiple values and requires at least one value
///
/// min gets corrected to be at least 1
/// max with 0 gets interpreted as inf
pub fn multiOption(name: Name, min: ?usize, max: ?usize, description: ?[]const u8) Arg {
    return Arg{
        .name = name,
        .description = description,

        .min_values = if (min) |v| @max(v, 1) else 1,
        .max_values = if (max) |v| v else 1,
    };
}

pub fn positional(name: []const u8, description: ?[]const u8, index: ?usize, required: Required) Arg {
    return Arg{
        .name = .{ .long = name },
        .description = description,

        .min_values = 1,
        .max_values = 1,

        .index = index,
        .required = required,
    };
}

/// min gets corrected to be at least 1
/// max with 0 gets interpreted as inf
pub fn multiPositional(name: []const u8, min: usize, max: usize, description: ?[]const u8, index: ?usize, required: Required) Arg {
    return Arg{
        .name = .{ .long = name },
        .description = description,

        .min_values = @max(min, 1),
        .max_values = max,

        .index = index,
        .required = required,
    };
}

/// min gets corrected to be at least 1
/// max with 0 gets interpreted as inf
pub fn select(name: Name, valid_values: []const []const u8, min: ?usize, max: ?usize, delimiter: ?[]const u8, descripion: ?[]const u8) Arg {
    return Arg{
        .name = name,
        .description = descripion,

        .min_values = if (min) |v| @max(v, 1) else 1,
        .max_values = if (max) |v| v else 1,

        .valid_values = valid_values,
        .values_delimiter = delimiter,
    };
}

pub const Name = union(enum) {
    long: []const u8,
    short: u8,
    both: Both,

    pub fn hasLongName(self: *const Name) bool {
        return self.* == .long or self.* == .both;
    }

    pub fn getLongName(self: *const Name) []const u8 {
        std.debug.assert(self.hasLongName());
        return switch (self.*) {
            .long => |name| name,
            .short => unreachable,
            .both => |both| both.long,
        };
    }

    pub fn hasShort(self: *const Name) bool {
        return self.* == .short or self.* == .both;
    }

    pub fn getShort(self: *const Name) u8 {
        std.debug.assert(self.hasShort());
        return switch (self.*) {
            .long => unreachable,
            .short => |short| short,
            .both => |both| both.short,
        };
    }

    pub const Both = struct {
        long: []const u8,
        short: u8,
    };
};

pub const Required = enum {
    not_required,
    required,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,

    name: Name,
    description: ?[]const u8 = null,

    min_values: usize = 0,
    max_values: usize = 0,

    values_placeholder: ?std.ArrayList([]const u8) = null,
    valid_values: ?std.ArrayList([]const u8) = null,
    values_delimiter: ?[]const u8 = null,

    index: ?usize = null,
    required: Required = .not_required,

    pub fn init(allocator: std.mem.Allocator, name: Name) std.mem.Allocator.Error!Builder {
        const owned_name: Name = try cloneName(allocator, name);
        errdefer freeName(allocator, name);

        return Builder{
            .allocator = allocator,

            .name = owned_name,
        };
    }

    pub fn initFromArg(allocator: std.mem.Allocator, arg: *const Arg) std.mem.Allocator.Error!Builder {
        const name = try cloneName(allocator, arg.name);
        errdefer freeName(allocator, name);

        const description = if (arg.description) |desc|
            try allocator.dupe(u8, desc)
        else
            null;
        errdefer if (description) |desc| {
            allocator.free(desc);
        };

        const values_placeholder: ?std.ArrayList([]const u8) = blk: {
            if (arg.values_placeholder == null) {
                break :blk null;
            }
            const values_placeholder = arg.values_placeholder.?;

            const clone_values_placeholder = try std.ArrayList([]const u8).initCapacity(allocator, values_placeholder.len);
            errdefer clone_values_placeholder.deinit(allocator);

            errdefer {
                for (clone_values_placeholder.items) |placeholder| {
                    allocator.free(placeholder);
                }
            }
            for (values_placeholder) |placeholder| {
                clone_values_placeholder.appendAssumeCapacity(try allocator.dupe(u8, placeholder));
            }

            break :blk clone_values_placeholder;
        };
        errdefer if (values_placeholder) |values| {
            for (values.items) |placeholder| {
                allocator.free(placeholder);
            }
            values.deinit(allocator);
        };

        const valid_values: ?std.ArrayList([]const u8) = blk: {
            if (arg.valid_values == null) {
                break :blk null;
            }
            const valid_values = arg.valid_values.?;

            const clone_valid_values = try std.ArrayList([]const u8).initCapacity(allocator, valid_values.len);
            errdefer clone_valid_values.deinit(allocator);

            errdefer {
                for (clone_valid_values.items) |value| {
                    allocator.free(value);
                }
            }
            for (valid_values) |value| {
                clone_valid_values.appendAssumeCapacity(try allocator.dupe(u8, value));
            }

            break :blk clone_valid_values;
        };
        errdefer if (valid_values) |values| {
            for (values.items) |value| {
                allocator.free(value);
            }
            values.deinit(allocator);
        };

        const value_delimiter = if (arg.values_delimiter) |delimiter|
            try allocator.dupe(delimiter)
        else
            null;
        errdefer if (value_delimiter) |delimiter| {
            allocator.free(delimiter);
        };

        return Builder{
            .allocator = allocator,

            .name = name,
            .description = description,

            .min_values = arg.min_values,
            .max_values = arg.max_values,

            .values_placeholder = values_placeholder,
            .valid_values = valid_values,
            .value_delimiter = value_delimiter,

            .index = arg.index,
            .required = arg.required,
        };
    }

    pub fn clone(self: *Builder, allocator: std.mem.Allocator) std.mem.Allocator.Error!Builder {
        const name = try cloneName(self.name);
        errdefer freeName(name);

        const description = if (self.description) |desc|
            try allocator.dupe(u8, desc)
        else
            null;
        errdefer if (description) |desc| {
            allocator.free(desc);
        };

        const values_placeholder: ?std.ArrayList([]const u8) = blk: {
            if (self.values_placeholder == null) {
                break :blk null;
            }
            const values_placeholder = self.values_placeholder.?;

            const clone_values_placeholder = try std.ArrayList([]const u8).initCapacity(allocator, values_placeholder.items.len);
            errdefer clone_values_placeholder.deinit(allocator);

            errdefer {
                for (clone_values_placeholder.items) |placeholder| {
                    allocator.free(placeholder);
                }
            }
            for (values_placeholder.items) |placeholder| {
                clone_values_placeholder.appendAssumeCapacity(try allocator.dupe(u8, placeholder));
            }

            break :blk clone_values_placeholder;
        };
        errdefer if (values_placeholder) |values| {
            for (values.items) |placeholder| {
                allocator.free(placeholder);
            }
            values.deinit(allocator);
        };

        const valid_values: ?std.ArrayList([]const u8) = blk: {
            if (self.valid_values == null) {
                break :blk null;
            }
            const valid_values = self.valid_values.?;

            const clone_valid_values = try std.ArrayList([]const u8).initCapacity(allocator, valid_values.items.len);
            errdefer clone_valid_values.deinit(allocator);

            errdefer {
                for (clone_valid_values.items) |value| {
                    allocator.free(value);
                }
            }
            for (valid_values.items) |value| {
                clone_valid_values.appendAssumeCapacity(try allocator.dupe(u8, value));
            }

            break :blk clone_valid_values;
        };
        errdefer if (valid_values) |values| {
            for (values.items) |value| {
                allocator.free(value);
            }
            values.deinit(allocator);
        };

        const value_delimiter = if (self.values_delimiter) |delimiter|
            try allocator.dupe(delimiter)
        else
            null;
        errdefer if (value_delimiter) |delimiter| {
            allocator.free(delimiter);
        };

        return Builder{
            .allocator = allocator,

            .name = name,
            .description = description,

            .min_values = self.min_values,
            .max_values = self.max_values,

            .values_placeholder = values_placeholder,
            .valid_values = valid_values,
            .value_delimiter = value_delimiter,

            .index = self.index,
            .required = self.required,
        };
    }

    pub fn deinit(self: *Builder) void {
        freeName(self.allocator, self.name);
        if (self.description) |desc| {
            self.allocator.free(desc);
        }

        if (self.values_placeholder) |values_placeholder| {
            for (values_placeholder.items) |value_placeholder| {
                self.allocator.free(value_placeholder);
            }
            values_placeholder.deinit(self.allocator);
        }
        if (self.valid_values) |valid_values| {
            for (valid_values.items) |valid_value| {
                self.allocator.free(valid_value);
            }
            valid_values.deinit(self.allocator);
        }
        if (self.values_delimiter) |values_delimiter| {
            self.allocator.free(values_delimiter);
        }
    }

    pub fn setName(self: *Builder, value: Name) std.mem.Allocator.Error!void {
        freeName(self.allocator, self.name);
        self.name = try cloneName(self.allocator, value);
    }

    pub fn setDescription(self: *Builder, value: []const u8) std.mem.Allocator.Error!void {
        if (self.description) |desc| {
            self.allocator.free(desc);
        }
        self.description = try self.allocator.dupe(u8, value);
    }

    pub fn setMin(self: *Builder, value: usize) void {
        self.min_values = value;
    }

    pub fn setMax(self: *Builder, value: usize) void {
        self.max_values = value;
    }

    pub fn addValuePlaceholders(self: *Builder, placeholders: []const []const u8) std.mem.Allocator.Error!void {
        if (self.values_placeholder == null) {
            self.values_placeholder = .empty;
        }
        const values_placeholder = &self.values_placeholder.?;
        try values_placeholder.ensureUnusedCapacity(self.allocator, placeholders.len);

        var i: usize = 0;
        errdefer {
            for (0..i) |_| {
                self.allocator.free(values_placeholder.pop().?);
            }
        }
        for (placeholders) |placeholder| {
            values_placeholder.appendAssumeCapacity(
                self.allocator,
                try self.allocator.dupe(u8, placeholder),
            );
            i += 1;
        }
    }

    pub fn addValidValues(self: *Builder, values: []const []const u8) std.mem.Allocator.Error!void {
        if (self.valid_values == null) {
            self.valid_values = .empty;
        }
        const valid_values = &self.valid_values.?;
        try valid_values.ensureUnusedCapacity(self.allocator, values.len);

        var i: usize = 0;
        errdefer {
            for (0..i) |_| {
                self.allocator.free(valid_values.pop().?);
            }
        }
        for (values) |value| {
            valid_values.appendAssumeCapacity(
                self.allocator,
                try self.allocator.dupe(u8, value),
            );
            i += 1;
        }
    }

    pub fn setValueDelimiter(self: *Builder, delimiter: []const u8) std.mem.Allocator.Error!void {
        if (self.values_delimiter) |value_delimiter| {
            self.allocator.free(value_delimiter);
        }
        self.values_delimiter = delimiter;
    }

    pub fn setIndex(self: *Builder, index: usize) void {
        self.index = index;
    }

    pub fn setRequired(self: *Builder) void {
        self.required = .required;
    }

    pub fn build(self: *Builder) std.mem.Allocator.Error!Build {
        const name = try cloneName(self.allocator, self.name);
        errdefer freeName(self.allocator, name);

        const description = if (self.description) |desc|
            try self.allocator.dupe(u8, desc)
        else
            null;
        errdefer if (description) |desc| {
            self.allocator.free(desc);
        };

        const values_placeholder: ?[]const []const u8 = blk: {
            if (self.values_placeholder == null) {
                break :blk null;
            }
            const values_placeholder = self.values_placeholder.?;

            const clone_values_placeholder = try self.allocator.alloc([]const u8, values_placeholder.items.len);
            errdefer self.allocator.free(clone_values_placeholder);

            var i: usize = 0;
            errdefer {
                for (0..i) |j| {
                    self.allocator.free(clone_values_placeholder[j]);
                }
            }
            for (values_placeholder.items) |placeholder| {
                clone_values_placeholder[i] = try self.allocator.dupe(u8, placeholder);
                i += 1;
            }

            break :blk clone_values_placeholder;
        };
        errdefer if (values_placeholder) |values| {
            for (values) |placeholder| {
                self.allocator.free(placeholder);
            }
            self.allocator.free(values);
        };

        const valid_values: ?[]const []const u8 = blk: {
            if (self.valid_values == null) {
                break :blk null;
            }
            const valid_values = self.valid_values.?;

            const clone_valid_values = try self.allocator.alloc([]const u8, valid_values.items.len);
            errdefer self.allocator.free(clone_valid_values);

            var i: usize = 0;
            errdefer {
                for (0..i) |j| {
                    self.allocator.free(clone_valid_values[j]);
                }
            }
            for (valid_values.items) |value| {
                clone_valid_values[i] = try self.allocator.dupe(u8, value);
                i += 1;
            }

            break :blk clone_valid_values;
        };
        errdefer if (valid_values) |values| {
            for (values) |value| {
                self.allocator.free(value);
            }
            self.allocator.free(values);
        };

        const value_delimiter = if (self.values_delimiter) |delimiter|
            try self.allocator.dupe(delimiter)
        else
            null;
        errdefer if (value_delimiter) |delimiter| {
            self.allocator.free(delimiter);
        };

        return Build{
            .allocator = self.allocator,

            .arg = Arg{
                .name = name,
                .description = description,

                .min_values = self.min_values,
                .max_values = self.max_values,

                .values_placeholder = values_placeholder,
                .valid_values = valid_values,
                .values_delimiter = value_delimiter,

                .index = self.index,
                .required = self.required,
            },
        };
    }
};

pub const Build = struct {
    allocator: std.mem.Allocator,

    arg: Arg,

    pub fn deinit(self: *Build) void {
        freeName(self.arg.name);
        if (self.arg.description) |desc| {
            self.allocator.free(desc);
        }

        if (self.arg.values_placeholder) |value_placeholder| {
            self.allocator.free(value_placeholder);
        }
        if (self.arg.valid_values) |valid_values| {
            for (valid_values) |valid_value| {
                self.allocator.free(valid_value);
            }
            self.allocator.free(valid_values);
        }
        if (self.arg.values_delimiter) |values_delimiter| {
            self.allocator.free(values_delimiter);
        }
    }
};

fn cloneName(allocator: std.mem.Allocator, name: Name) std.mem.Allocator.Error!void {
    return switch (name) {
        .short => name,
        .long => |n| Name{ .long = try allocator.dupe(u8, n) },
        .both => |both| Name{ .both = .{
            .name = try allocator.dupe(u8, both.long),
            .short = both.short,
        } },
    };
}

fn freeName(allocator: std.mem.Allocator, name: Name) void {
    switch (name) {
        .short => {},
        .long => |n| allocator.free(n),
        .both => |both| allocator.free(both.long),
    }
}
