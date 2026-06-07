//! ez-checker — minimal TS-flavored type inference and assignability
//! sufficient for the `no-unsafe-*` family of typescript-eslint rules.
//!
//! Not a full TS implementation: we lean on annotations, do not perform
//! generic inference, and treat unresolved references as `any`.
//!
//! Cross-file module resolution is NOT included here.  Callers that need
//! it should implement `Checker.ModuleResolver` and supply it via the
//! `module_resolver` field after `Checker.init`.

pub const types = @import("types.zig");
pub const Checker = @import("checker.zig").Checker;
pub const ModuleResolver = @import("checker.zig").ModuleResolver;
pub const EnumKind = @import("checker.zig").EnumKind;
pub const ImportEntry = @import("checker.zig").ImportEntry;

test {
    _ = types;
    _ = @import("checker.zig");
}
