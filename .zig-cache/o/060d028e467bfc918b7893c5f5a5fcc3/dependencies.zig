pub const packages = struct {
    pub const @"../es-parser" = struct {
        pub const build_root = "/Users/ericsan/Development/OpenSource/ez-checker/../es-parser";
        pub const build_zig = @import("../es-parser");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "es_parser", "../es-parser" },
};
