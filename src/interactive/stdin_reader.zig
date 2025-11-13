const std = @import("std");
const builtin = @import("builtin");

const StdInReader = @This();



pub fn hasData(self: *const StdInReader) bool {
    _ = self;
    
    if (builtin.os.tag == .windows) {
        return hasDataWindows();
    } else {
        return hasDataPosix();
    }
}

fn hasDataWindows() bool {
    const c = @cImport({
        @cInclude("conio.h");
    });

    return c.kbhit() == 1;
}

fn hasDataPosix() bool {
    @compileError("not implemented");
}
