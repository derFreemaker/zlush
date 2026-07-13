const std = @import("std");

const Arg = @import("Arg.zig");

const Command = @This();

name: []const u8,
description: ?[]const u8 = null,

args: []const Arg = &.{},
subcommands: []const Command = &.{},

effects: Effects = .{},

pub const Effects = packed struct(u8) {
    help_on_empty_args: bool = false,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,

    name: []const u8,
    description: ?[]const u8 = null,

    args: std.ArrayList(Arg.Builder) = .empty,
    subcommands: std.ArrayList(Builder) = .empty,

    effects: Command.Effects = .{},

    pub fn init(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!Builder {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        return Builder{
            .allocator = allocator,

            .name = owned_name,
        };
    }

    pub fn initFromCommand(allocator: std.mem.Allocator, command: *const Command) Builder {
        const name = try allocator.dupe(u8, command.name);
        errdefer allocator.free(name);

        const description: ?[]const u8 = if (command.description) |desc|
            try allocator.dupe(u8, desc)
        else
            null;
        errdefer if (description) |desc| allocator.free(desc);

        const args = try std.ArrayList(Arg.Builder).initCapacity(allocator, command.args.len);
        errdefer {
            for (args.items) |*arg| {
                arg.deinit();
            }
            args.deinit(allocator);
        }
        for (command.args) |arg| {
            args.appendAssumeCapacity(try .initFromArg(allocator, arg));
        }

        const subcommands = try std.ArrayList(Builder).initCapacity(allocator, command.subcommands.len);
        errdefer {
            for (subcommands.items) |*subcommand| {
                subcommand.deinit();
            }
            subcommands.deinit(allocator);
        }
        for (command.subcommands) |subcommand| {
            subcommands.appendAssumeCapacity(try .initFromCommand(subcommand));
        }

        return Builder{
            .allocator = allocator,

            .name = name,
            .description = description,

            .args = args,
            .subcommand = subcommands,

            .effects = command.effects,
        };
    }

    pub fn clone(self: *Builder, allocator: std.mem.Allocator) std.mem.Allocator.Error!Builder {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);

        const description: ?[]const u8 = if (self.description) |desc|
            try allocator.dupe(u8, desc)
        else
            null;
        errdefer if (description) |desc| allocator.free(desc);

        const args = try std.ArrayList(Arg.Builder).initCapacity(allocator, self.args.items.len);
        errdefer {
            for (args.items) |*arg| {
                arg.deinit();
            }
            args.deinit(allocator);
        }
        for (self.args.items) |builder| {
            args.appendAssumeCapacity(try builder.clone());
        }

        const subcommands = try std.ArrayList(Builder).initCapacity(allocator, self.subcommands.items.len);
        errdefer {
            for (subcommands.items) |*subcommand| {
                subcommand.deinit();
            }
            subcommands.deinit(allocator);
        }
        for (self.subcommands.items) |subcommand| {
            subcommands.appendAssumeCapacity(try .initFromCommand(subcommand));
        }

        return Builder{
            .allocator = allocator,

            .name = name,
            .description = description,

            .args = args,
            .subcommands = subcommands,

            .effects = self.effects,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.args.deinit(self.allocator);

        for (self.subcommands.items) |*subcommand| {
            subcommand.deinit();
        }
        self.subcommands.deinit(self.allocator);
    }

    pub fn setDescription(self: *Builder, value: []const u8) std.mem.Allocator.Error!void {
        if (self.description) |desc| {
            self.allocator.free(desc);
        }
        self.description = try self.allocator.dupe(u8, value);
    }

    pub fn helpOnEmptyArgs(self: *Builder) void {
        self.effects.help_on_empty_args = true;
    }

    pub fn addArgs(self: *Builder, args: []const Arg) std.mem.Allocator.Error!void {
        try self.args.ensureUnusedCapacity(self.allocator, args.len);

        for (args) |arg| {
            self.args.appendAssumeCapacity(try .initFromArg(self.allocator, &arg));
        }
    }

    pub fn addArgBuilders(self: *Builder, args: []const Arg.Builder) std.mem.Allocator.Error!void {
        try self.args.ensureUnusedCapacity(self.allocator, args.len);

        for (args) |builder| {
            self.args.appendAssumeCapacity(try builder.clone());
        }
    }

    pub fn addCommands(self: *Builder, subcommands: []const Command) std.mem.Allocator.Error!void {
        try self.subcommands.ensureUnusedCapacity(self.allocator, subcommands.len);

        for (subcommands) |subcommand| {
            self.subcommands.appendAssumeCapacity(try .initFromCommand(self.allocator, &subcommand));
        }
    }

    pub fn addCommandBuilders(self: *Builder, subcommands: []const Builder) std.mem.Allocator.Error!void {
        try self.subcommands.ensureUnusedCapacity(self.allocator, subcommands.len);

        for (subcommands) |builder| {
            self.subcommands.appendAssumeCapacity(try builder.clone());
        }
    }

    pub fn build(self: *Builder, allocator: std.mem.Allocator) std.mem.Allocator.Error!Build {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);

        const description = if (self.description) |desc|
            try allocator.dupe(u8, desc)
        else
            null;
        errdefer if (description) |desc| {
            allocator.free(desc);
        };

        const args = try allocator.alloc(Arg, self.args.items.len);
        errdefer allocator.free(args);
        @memcpy(args, self.args.items);

        const subcommands = try allocator.alloc(Command, self.subcommands.items.len);
        errdefer allocator.free(subcommands);

        var i: usize = 0;
        errdefer {
            for (0..i) |j| {
                const build_subcommand = Build{
                    .allocator = allocator,
                    .command = subcommands[j],
                };
                build_subcommand.deinit();
            }
        }
        for (self.subcommands.items) |subcommand| {
            const buildCommand = try subcommand.build(allocator);
            subcommands[i] = buildCommand.command;
            i += 1;
        }

        return Build{
            .allocator = allocator,

            .command = Command{
                .name = name,
                .description = description,

                .args = args,
                .subcommands = subcommands,

                .effects = self.effects,
            },
        };
    }
};

pub const Build = struct {
    allocator: std.mem.Allocator,

    command: Command,

    fn freeCommand(allocator: std.mem.Allocator, command: *Command) void {
        allocator.free(command.name);
        if (command.description) |desc| {
            allocator.free(desc);
        }

        allocator.free(command.args);
        for (command.subcommands) |*subcommand| {
            freeCommand(allocator, subcommand);
        }
        allocator.free(command.subcommands);
    }

    pub fn deinit(self: *Build) void {
        freeCommand(self.allocator, &self.command);
    }
};
