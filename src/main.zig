const std = @import("std");
const builtin = @import("builtin");

// const zlush = @import("zlush");

var state: zlush_main = undefined;

pub fn main() !u8 {
    var gpa = std.heap.DebugAllocator(if (builtin.mode == .Debug) .{
        .retain_metadata = true,
        .never_unmap = true,
    } else .{}){};
    const allocator = gpa.allocator();

    state = try zlush_main.init(allocator);
    defer state.deinit();

    while (true) {
        const command = try state.promptUser();
        defer allocator.free(command);

        if (std.mem.eql(u8, command, "exit")) {
            return 0;
        }

        try state.stdout.interface.writeAll(command);
        try state.stdout.interface.writeByte('\n');
        try state.stdout.interface.flush();
    }
}

fn handleSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    state.input_canceled.store(true, .seq_cst);
}

fn handleConsoleCtrl(dwCtrlType: u32) callconv(.c) i32 {
    _ = dwCtrlType;
    state.input_canceled.store(true, .seq_cst);
    return 1;
}

const zlush_main = struct {
    const Self = @This();

    input_canceled: std.atomic.Value(bool) = .init(false),
    
    allocator: std.mem.Allocator,
    
    stdin_buf: []u8,
    stdin: std.fs.File.Reader,

    stdout_buf: []u8,
    stdout: std.fs.File.Writer,

    stderr_buf: []u8,
    stderr: std.fs.File.Writer,

    pub fn init(allocator: std.mem.Allocator) error{ FailedToSetHandler, OutOfMemory }!Self {
        // Setup signal handlers
        if (builtin.os.tag == .windows) {
            if (std.os.windows.kernel32.SetConsoleCtrlHandler(handleConsoleCtrl, 1) == 0) {
                return error.FailedToSetHandler;
            }
        } else {
            const posix = std.posix;
            var act = posix.Sigaction{
                .handler = .{ .handler = handleSignal },
                .mask = posix.empty_sigset,
                .flags = 0,
            };
            posix.sigaction(posix.SIG.INT, &act, null);
        }

        const stdin_buf = try allocator.alloc(u8, 256);
        const stdout_buf = try allocator.alloc(u8, 1024);
        const stderr_buf = try allocator.alloc(u8, 1024);

        return Self{
            .allocator = allocator,

            .stdin_buf = stdin_buf,
            .stdin = std.fs.File.stdin().reader(stdin_buf),

            .stdout_buf = stdout_buf,
            .stdout = std.fs.File.stdout().writer(stdout_buf),

            .stderr_buf = stderr_buf,
            .stderr = std.fs.File.stderr().writer(stderr_buf),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.stdin_buf);
        self.allocator.free(self.stdout_buf);
        self.allocator.free(self.stderr_buf);
    }

    pub fn promptUser(self: *Self) ![]const u8 {
        while (true) {
            try self.stdout.interface.writeAll("zlush> ");
            try self.stdout.interface.flush();

            const command = self.readCommand() catch |err| switch (err) {
                error.CommandCanceled => {
                    try self.stdout.interface.writeAll("^C\n");
                    try self.stdout.interface.flush();
                    continue;
                },
                else => return err,
            };

            return command;
        }
    }
    
    pub fn readCommand(self: *Self) error{ ReadingCommandFailed, EndOfStream, OutOfMemory, CommandCanceled }![]const u8 {
        self.input_canceled.store(false, .seq_cst);

        var command_writer = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
        defer command_writer.deinit();

        read_byte: while (true) {
            if (self.input_canceled.load(.seq_cst)) {
                return error.CommandCanceled;
            }

            const byte = self.stdin.interface.peekByte() catch |err| switch (err) {
                error.ReadFailed => return error.ReadingCommandFailed,
                error.EndOfStream => {
                    continue :read_byte;
                },
            };
            self.stdin.interface.toss(1);
            
            if (byte == '\n') {
                break;
            }
            command_writer.writer.writeByte(byte) catch return error.ReadingCommandFailed;
        }

        const command_buf = command_writer.written();
        const command = if (std.mem.endsWith(u8, command_buf, "\r")) command_buf[0 .. command_writer.written().len - 1] else command_buf;
        return try self.allocator.dupe(u8, command);
    }
};
