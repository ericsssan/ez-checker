const std = @import("std");
pub const Ctx = struct {
    pub fn end(_: Ctx) void {}
};
pub fn trace(_: std.builtin.SourceLocation) Ctx {
    return .{};
}
pub fn traceNamed(_: std.builtin.SourceLocation, _: []const u8) Ctx {
    return .{};
}
