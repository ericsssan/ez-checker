const std = @import("std");

pub const Builtin = struct {
    return_type: []const u8,
    documentation: []const u8,
    parameters: []const Parameter,

    pub const Parameter = struct {
        signature: []const u8,
        documentation: ?[]const u8,
    };
};

pub const builtins: std.StaticStringMap(Builtin) = .initComptime(&[_]struct { []const u8, Builtin }{});
