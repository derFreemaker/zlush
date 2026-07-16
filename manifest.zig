name: enum { zlush },
version: []const u8,
fingerprint: u64,
minimum_zig_version: []const u8,
dependencies: struct {
    tracy: Dependency,
    zttio: Dependency,
    zag: Dependency,
},
paths: []const []const u8,

const Dependency = struct { url: []const u8, hash: []const u8, lazy: bool = false };
