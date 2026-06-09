//! ez-checker — TypeScript type checker for lint rules.
//!
//! Per-file inference over a parsed AST: literals, unions, intersections,
//! generics, conditional types, mapped types, utility types, control-flow
//! narrowing, and structural inheritance.  Unresolved references produce
//! `error` or `unknown` (not `any`) so rules can distinguish them.
//!
//! Cross-file resolution is optional: implement `ModuleResolver` and set
//! `Checker.module_resolver` to enable lazy import type resolution.

pub const types = @import("types.zig");
pub const Checker = @import("checker.zig").Checker;
pub const CheckerOpts = @import("checker.zig").CheckerOpts;
pub const ModuleResolver = @import("checker.zig").ModuleResolver;
pub const EnumKind = @import("checker.zig").EnumKind;
pub const ImportEntry = @import("checker.zig").ImportEntry;

test {
    _ = types;
    _ = @import("checker.zig");
}
