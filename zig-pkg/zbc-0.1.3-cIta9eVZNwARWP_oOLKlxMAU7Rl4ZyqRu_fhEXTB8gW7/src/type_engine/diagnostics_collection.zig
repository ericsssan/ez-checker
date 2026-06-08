const std = @import("std");

pub const DiagnosticsCollection = @This();

pub const Tag = enum(u32) { _ };

io: std.Io,
allocator: std.mem.Allocator,

pub fn deinit(_: *DiagnosticsCollection) void {}

pub fn pushErrorBundle(
    _: *DiagnosticsCollection,
    _: anytype,
    _: u32,
    _: ?[]const u8,
    _: std.zig.ErrorBundle,
) error{OutOfMemory}!void {}

pub fn publishDiagnostics(_: *DiagnosticsCollection) error{OutOfMemory}!void {}
