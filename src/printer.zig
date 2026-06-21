//! Printer — renders a `TypeId` to its TypeScript-source string form.
//!
//! Split out of checker.zig: this is the rendering surface (tsc's
//! `typeToString` / `typeToStringInner`) plus the small property-quoting
//! helper. It operates over a `*Checker` passed by parameter rather than
//! owning state, because the render state it reads — the type store, the
//! `<T>` type-parameter prefix caches (`sig_type_params`/`fn_type_params`),
//! and `render_location` — is co-owned with the type-builder and stays on
//! Checker. So this is a module split for navigability and an explicit,
//! one-way dependency, NOT a decoupling: the printer needs the whole
//! Checker, and pretending otherwise (a struct with a back-pointer) would
//! only relocate the coupling.

const std = @import("std");
const parser = @import("es_parser");
const ast = parser.ast;
const NodeIndex = ast.NodeIndex;

const tymod = @import("types.zig");
const TypeId = tymod.TypeId;

const checker_mod = @import("checker.zig");
const Checker = checker_mod.Checker;

pub fn typeToString(c: *Checker, id: TypeId) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(c.gpa);
    try typeToStringInner(c, id, &buf, 0);
    return buf.toOwnedSlice(c.gpa);
}

/// Location-aware render (tsc's typeToString with an enclosingDeclaration):
/// renders `id` as seen from `location`, qualifying named types relative to
/// that node's scope. With `location == .none` this is exactly `typeToString`.
pub fn typeToStringAt(c: *Checker, id: TypeId, location: NodeIndex) ![]const u8 {
    const prev = c.render_location;
    c.render_location = location;
    defer c.render_location = prev;
    return typeToString(c, id);
}

fn typeToStringInner(c: *Checker, id: TypeId, buf: *std.ArrayList(u8), depth: u8) !void {
    const gpa = c.gpa;
    if (depth > 8) {
        try buf.appendSlice(gpa, "...");
        return;
    }
    const t = c.store.get(id);
    // Display-only override (the render/compute split): a `typeof X` query
    // type renders verbatim while keeping its structure for computation.
    if (t.display_name.len > 0) {
        try buf.appendSlice(gpa, t.display_name);
        return;
    }
    switch (t.kind) {
        .any         => try buf.appendSlice(gpa, "any"),
        .unknown     => try buf.appendSlice(gpa, "unknown"),
        .never       => try buf.appendSlice(gpa, "never"),
        .null_t      => try buf.appendSlice(gpa, "null"),
        .undefined_t => try buf.appendSlice(gpa, "undefined"),
        .void_t      => try buf.appendSlice(gpa, "void"),
        .number, .string => {
            // Opaque (computed-initializer) enum members display E.A.
            if (t.enum_name.len > 0 and t.alias_name.len > 0) {
                try buf.appendSlice(gpa, t.alias_name);
            } else if (t.enum_name.len > 0 and t.name.len > 0) {
                try buf.appendSlice(gpa, t.enum_name);
                try buf.append(gpa, '.');
                try buf.appendSlice(gpa, t.name);
            } else {
                try buf.appendSlice(gpa, if (t.kind == .number) "number" else "string");
            }
        },
        .boolean     => try buf.appendSlice(gpa, "boolean"),
        .bigint      => try buf.appendSlice(gpa, "bigint"),
        .symbol      => try buf.appendSlice(gpa, "symbol"),
        .object_keyword => try buf.appendSlice(gpa, "object"),
        .error_t     => try buf.appendSlice(gpa, "error"),
        .type_ref => {
            // An alias-tagged type_ref renders by its alias display (e.g. an
            // expanded mapped-type body that's the body of `Boxified<T>` shows
            // `Boxified<T>`, not the mapped syntax).
            if (t.alias_name.len > 0) {
                try buf.appendSlice(gpa, t.alias_name);
                return;
            }
            const args = c.store.idsOf(t.list_data);
            // TypeScript always renders Array<T> as T[] in output
            if (std.mem.eql(u8, t.name, "Array") and args.len == 1) {
                try typeToStringInner(c, args[0], buf, depth + 1);
                try buf.appendSlice(gpa, "[]");
                return;
            }
            // TypeScript renders ReadonlyArray<T> as readonly T[]
            if (std.mem.eql(u8, t.name, "ReadonlyArray") and args.len == 1) {
                try buf.appendSlice(gpa, "readonly ");
                try typeToStringInner(c, args[0], buf, depth + 1);
                try buf.appendSlice(gpa, "[]");
                return;
            }
            // Context-aware qualification (tsc's enclosingDeclaration): a user
            // named type renders qualified (`A.Point`) when its bare name is
            // NOT accessible from the print location.
            if (t.symbol_scope.len > 0) {
                if (c.qualificationPrefix(t.name, t.symbol_scope)) |prefix| {
                    try buf.appendSlice(gpa, prefix);
                    try buf.append(gpa, '.');
                }
            }
            try buf.appendSlice(gpa, t.name);
            if (args.len > 0) {
                try buf.append(gpa, '<');
                for (args, 0..) |arg, ai| {
                    if (ai > 0) try buf.appendSlice(gpa, ", ");
                    try typeToStringInner(c, arg, buf, depth + 1);
                }
                try buf.append(gpa, '>');
            }
        },
        .type_param  => {
            if (t.alias_name.len > 0) {
                try buf.appendSlice(gpa, t.alias_name);
            } else {
                try buf.appendSlice(gpa, t.name);
            }
        },
        .string_literal => {
            // String enum members render as EnumName.MemberName; a
            // single-member enum's lone member is aliased to the enum name.
            if (t.enum_name.len > 0 and t.alias_name.len > 0) {
                try buf.appendSlice(gpa, t.alias_name);
            } else if (t.enum_name.len > 0 and t.name.len > 0) {
                try buf.appendSlice(gpa, t.enum_name);
                try buf.append(gpa, '.');
                try buf.appendSlice(gpa, t.name);
            } else {
            try buf.append(gpa, '"');
            const slit = t.literal_value.string;
            var si: usize = 0;
            while (si < slit.len) : (si += 1) {
                const byte = slit[si];
                if (byte == 0x00) {
                    // TypeScript renders the null byte as \0, but uses \x00 when
                    // followed by a decimal digit to avoid ambiguity.
                    const next_is_digit = si + 1 < slit.len and slit[si + 1] >= '0' and slit[si + 1] <= '9';
                    if (next_is_digit) {
                        try buf.appendSlice(gpa, "\\x00");
                    } else {
                        try buf.appendSlice(gpa, "\\0");
                    }
                } else if (byte < 0x20) {
                    // Named escape sequences for common control chars (matching tsc output)
                    switch (byte) {
                        0x08 => try buf.appendSlice(gpa, "\\b"),
                        0x09 => try buf.appendSlice(gpa, "\\t"),
                        0x0A => try buf.appendSlice(gpa, "\\n"),
                        0x0B => try buf.appendSlice(gpa, "\\v"),
                        0x0C => try buf.appendSlice(gpa, "\\f"),
                        0x0D => try buf.appendSlice(gpa, "\\r"),
                        else => try buf.print(gpa, "\\u{X:0>4}", .{byte}),
                    }
                } else if (byte == '"') {
                    try buf.appendSlice(gpa, "\\\"");
                } else if (byte == '\\') {
                    try buf.appendSlice(gpa, "\\\\");
                } else {
                    try buf.append(gpa, byte);
                }
            }
            try buf.append(gpa, '"');
            } // end else (not an enum member)
        },
        .number_literal => {
            // Enum member literals render as EnumName.MemberName (e.g. E.B).
            if (t.enum_name.len > 0 and t.alias_name.len > 0) {
                try buf.appendSlice(gpa, t.alias_name);
            } else if (t.enum_name.len > 0 and t.name.len > 0) {
                try buf.appendSlice(gpa, t.enum_name);
                try buf.append(gpa, '.');
                try buf.appendSlice(gpa, t.name);
            } else {
                const n = t.literal_value.number;
                if (std.math.isPositiveInf(n)) {
                    try buf.appendSlice(gpa, "Infinity");
                } else if (std.math.isNegativeInf(n)) {
                    try buf.appendSlice(gpa, "-Infinity");
                } else if (std.math.isNan(n)) {
                    try buf.appendSlice(gpa, "NaN");
                } else {
                    // Integer-valued literals print without a decimal point — but
                    // only when in i64 range, else @intFromFloat is UB (e.g. 1e300).
                    const i64_min: f64 = -9223372036854775808.0;
                    const i64_max: f64 = 9223372036854775808.0;
                    if (n == @trunc(n) and n >= i64_min and n < i64_max) {
                        try buf.print(gpa, "{d}", .{@as(i64, @intFromFloat(n))});
                    } else {
                        try buf.print(gpa, "{d}", .{n});
                    }
                }
            }
        },
        .boolean_literal => try buf.appendSlice(gpa, if (t.literal_value.boolean) "true" else "false"),
        .bigint_literal  => try buf.print(gpa, "{s}n", .{t.literal_value.bigint}),
        .array_t => {
            const ids = c.store.idsOf(t.list_data);
            if (ids.len > 0) {
                const elem = c.store.get(ids[0]);
                // An aliased type renders as a single identifier — no parens needed
                // regardless of underlying kind (`type Cleaner = () => void` → `Cleaner[]`,
                // not `(Cleaner)[]`).  Non-aliased multi-token kinds need parens.
                const multi_token_compound = (elem.kind == .union_t or elem.kind == .intersection_t) and
                    elem.alias_name.len == 0;
                const needs_parens = multi_token_compound or
                    (elem.kind == .function_t and elem.alias_name.len == 0) or
                    (elem.kind == .type_ref and std.mem.startsWith(u8, elem.name, "typeof "));
                if (needs_parens) try buf.appendSlice(gpa, "(");
                try typeToStringInner(c, ids[0], buf, depth + 1);
                if (needs_parens) try buf.appendSlice(gpa, ")");
            } else {
                try buf.appendSlice(gpa, "unknown");
            }
            try buf.appendSlice(gpa, "[]");
        },
        .readonly_array_t => {
            try buf.appendSlice(gpa, "readonly ");
            const ids = c.store.idsOf(t.list_data);
            if (ids.len > 0) {
                const elem = c.store.get(ids[0]);
                // Same parens logic as array_t.
                const multi_token_compound = (elem.kind == .union_t or elem.kind == .intersection_t) and
                    elem.alias_name.len == 0;
                const needs_parens = multi_token_compound or
                    (elem.kind == .function_t and elem.alias_name.len == 0) or
                    (elem.kind == .type_ref and std.mem.startsWith(u8, elem.name, "typeof "));
                if (needs_parens) try buf.appendSlice(gpa, "(");
                try typeToStringInner(c, ids[0], buf, depth + 1);
                if (needs_parens) try buf.appendSlice(gpa, ")");
            } else {
                try buf.appendSlice(gpa, "unknown");
            }
            try buf.appendSlice(gpa, "[]");
        },
        .tuple_t => {
            if (t.alias_name.len > 0) {
                try buf.appendSlice(gpa, t.alias_name);
                return;
            }
            if (t.name.len > 0) try buf.appendSlice(gpa, "readonly ");
            try buf.appendSlice(gpa, "[");
            for (c.store.idsOf(t.list_data), 0..) |m, i| {
                if (i > 0) try buf.appendSlice(gpa, ", ");
                const mt = c.store.get(m);
                if (mt.kind == .rest_t) {
                    try buf.appendSlice(gpa, "...");
                    const inner_ids = c.store.idsOf(mt.list_data);
                    if (inner_ids.len > 0) {
                        try typeToStringInner(c, inner_ids[0], buf, depth + 1);
                    }
                } else {
                    try typeToStringInner(c, m, buf, depth + 1);
                }
            }
            try buf.appendSlice(gpa, "]");
        },
        .rest_t => {
            // Shouldn't appear outside tuple context; serialize as `...T`.
            try buf.appendSlice(gpa, "...");
            const inner_ids = c.store.idsOf(t.list_data);
            if (inner_ids.len > 0) {
                try typeToStringInner(c, inner_ids[0], buf, depth + 1);
            }
        },
        .function_t => {
            // If tagged with a type-alias name, render as the alias (e.g. `type Handler = (...) => void`).
            if (t.alias_name.len > 0) {
                try buf.appendSlice(gpa, t.alias_name);
                return;
            }
            const sigs = c.store.signaturesOf(t.signatures);
            if (sigs.len == 0) {
                try buf.appendSlice(gpa, "() => unknown");
            } else if (sigs.len == 1 and !t.is_overload_set) {
                const sig = sigs[0];
                const params = c.store.signatureParamsOf(sig);
                const names = c.store.signatureParamNamesOf(sig);
                const opts = c.store.signatureParamOptionalsOf(sig);
                if (sig.is_construct) try buf.appendSlice(gpa, "new ");
                if (c.fn_type_params.get(id)) |tp_prefix|
                    try buf.appendSlice(gpa, tp_prefix);
                try buf.append(gpa, '(');
                for (params, 0..) |param_ty, pi| {
                    if (pi > 0) try buf.appendSlice(gpa, ", ");
                    const is_rest = sig.rest_param_index != 0xFFFF and pi == sig.rest_param_index;
                    if (is_rest) try buf.appendSlice(gpa, "...");
                    const pname = if (pi < names.len) names[pi] else "";
                    const is_opt = !is_rest and pi < opts.len and opts[pi];
                    if (pname.len > 0) {
                        try buf.appendSlice(gpa, pname);
                        if (is_opt) try buf.append(gpa, '?');
                        try buf.appendSlice(gpa, ": ");
                    }
                    try typeToStringInner(c, param_ty, buf, depth + 1);
                }
                try buf.appendSlice(gpa, ") => ");
                if (sig.predicate_param_index != 0xFFFF and sig.predicate_target != .none) {
                    const pred_name = if (sig.predicate_param_index == 0xFFFE) "this" else if (sig.predicate_param_index < names.len) names[sig.predicate_param_index] else "";
                    if (pred_name.len > 0) {
                        if (sig.is_assertion) try buf.appendSlice(gpa, "asserts ");
                        try buf.appendSlice(gpa, pred_name);
                        try buf.appendSlice(gpa, " is ");
                        try typeToStringInner(c, sig.predicate_target, buf, depth + 1);
                    } else {
                        try typeToStringInner(c, sig.return_type, buf, depth + 1);
                    }
                } else if (sig.is_assertion and sig.predicate_param_index != 0xFFFF) {
                    const pred_name = if (sig.predicate_param_index == 0xFFFE) "this" else if (sig.predicate_param_index < names.len) names[sig.predicate_param_index] else "";
                    if (pred_name.len > 0) {
                        try buf.appendSlice(gpa, "asserts ");
                        try buf.appendSlice(gpa, pred_name);
                    } else {
                        try typeToStringInner(c, sig.return_type, buf, depth + 1);
                    }
                } else {
                    try typeToStringInner(c, sig.return_type, buf, depth + 1);
                }
            } else {
                // Multi-signature (overloads) — tsc renders as { (p): T; (p): T; }
                try buf.appendSlice(gpa, "{ ");
                for (sigs, 0..) |sig, si| {
                    if (si > 0) try buf.appendSlice(gpa, "; ");
                    const params = c.store.signatureParamsOf(sig);
                    const names = c.store.signatureParamNamesOf(sig);
                    const opts = c.store.signatureParamOptionalsOf(sig);
                    const sig_pool_idx: u32 = t.signatures.start + @as(u32, @intCast(si));
                    if (c.sig_type_params.get(sig_pool_idx)) |tp_prefix| {
                        try buf.appendSlice(gpa, tp_prefix);
                    }
                    try buf.append(gpa, '(');
                    for (params, 0..) |param_ty, pi| {
                        if (pi > 0) try buf.appendSlice(gpa, ", ");
                        const is_rest = sig.rest_param_index != 0xFFFF and pi == sig.rest_param_index;
                        if (is_rest) try buf.appendSlice(gpa, "...");
                        const pname = if (pi < names.len) names[pi] else "";
                        const is_opt = !is_rest and pi < opts.len and opts[pi];
                        if (pname.len > 0) {
                            try buf.appendSlice(gpa, pname);
                            if (is_opt) try buf.append(gpa, '?');
                            try buf.appendSlice(gpa, ": ");
                        }
                        try typeToStringInner(c, param_ty, buf, depth + 1);
                    }
                    try buf.appendSlice(gpa, "): ");
                    try typeToStringInner(c, sig.return_type, buf, depth + 1);
                }
                try buf.appendSlice(gpa, "; }");
            }
        },
        .object_t => {
            // If tagged with a type-alias name (e.g. `type A = {...}`), render
            // as the alias name matching tsc, not the structural expansion.
            // Guard against internal sentinels like "__static__".
            if (t.alias_name.len > 0 and !std.mem.eql(u8, t.alias_name, "__static__")) {
                try buf.appendSlice(gpa, t.alias_name);
                return;
            }
            const props = c.store.propsOf(t.object_props);
            const call_sigs = c.store.signaturesOf(t.signatures);
            // Count renderable regular properties (skip index-signature sentinels).
            var real_count: usize = 0;
            var idx_sig_count: usize = 0;
            for (props) |p| {
                if (std.mem.startsWith(u8, p.name, "[]")) {
                    if (p.index_key_name.len > 0) idx_sig_count += 1;
                } else {
                    real_count += 1;
                }
            }
            // Single call/construct signature with no props: render as arrow form.
            if (real_count == 0 and call_sigs.len == 1 and idx_sig_count == 0) {
                const sig = call_sigs[0];
                const sparams = c.store.signatureParamsOf(sig);
                const snames = c.store.signatureParamNamesOf(sig);
                const sopts = c.store.signatureParamOptionalsOf(sig);
                if (sig.is_construct) try buf.appendSlice(gpa, "new ");
                if (c.sig_type_params.get(t.signatures.start)) |tp_prefix|
                    try buf.appendSlice(gpa, tp_prefix);
                try buf.append(gpa, '(');
                for (sparams, 0..) |sp, si| {
                    if (si > 0) try buf.appendSlice(gpa, ", ");
                    const is_rest = sig.rest_param_index != 0xFFFF and si == sig.rest_param_index;
                    if (is_rest) try buf.appendSlice(gpa, "...");
                    const sn = if (si < snames.len) snames[si] else "";
                    const is_opt = !is_rest and si < sopts.len and sopts[si];
                    if (sn.len > 0) {
                        try buf.appendSlice(gpa, sn);
                        if (is_opt) try buf.append(gpa, '?');
                        try buf.appendSlice(gpa, ": ");
                    }
                    try typeToStringInner(c, sp, buf, depth + 1);
                }
                try buf.appendSlice(gpa, ") => ");
                try typeToStringInner(c, sig.return_type, buf, depth + 1);
            } else if (real_count == 0 and call_sigs.len == 0 and idx_sig_count == 0) {
                try buf.appendSlice(gpa, "{}");
            } else {
                try buf.appendSlice(gpa, "{ ");
                var first = true;
                // Render call/construct signatures in object form.
                for (call_sigs, 0..) |sig, csi| {
                    if (!first) try buf.appendSlice(gpa, "; ");
                    first = false;
                    const sparams = c.store.signatureParamsOf(sig);
                    const snames = c.store.signatureParamNamesOf(sig);
                    const sopts = c.store.signatureParamOptionalsOf(sig);
                    if (sig.is_construct) try buf.appendSlice(gpa, "new ");
                    const pool_idx: u32 = t.signatures.start + @as(u32, @intCast(csi));
                    if (c.sig_type_params.get(pool_idx)) |tp_prefix| {
                        try buf.appendSlice(gpa, tp_prefix);
                    }
                    try buf.append(gpa, '(');
                    for (sparams, 0..) |sp, si| {
                        if (si > 0) try buf.appendSlice(gpa, ", ");
                        const is_rest = sig.rest_param_index != 0xFFFF and si == sig.rest_param_index;
                        if (is_rest) try buf.appendSlice(gpa, "...");
                        const sn = if (si < snames.len) snames[si] else "";
                        const is_opt = !is_rest and si < sopts.len and sopts[si];
                        if (sn.len > 0) {
                            try buf.appendSlice(gpa, sn);
                            if (is_opt) try buf.append(gpa, '?');
                            try buf.appendSlice(gpa, ": ");
                        }
                        try typeToStringInner(c, sp, buf, depth + 1);
                    }
                    try buf.appendSlice(gpa, "): ");
                    try typeToStringInner(c, sig.return_type, buf, depth + 1);
                }
                // Render index signatures (e.g. `[key: string]: T`).
                for (props) |p| {
                    if (!std.mem.startsWith(u8, p.name, "[]")) continue;
                    if (p.index_key_name.len == 0) continue; // skip synthetic/backward-compat entries
                    if (!first) try buf.appendSlice(gpa, "; ");
                    first = false;
                    try buf.append(gpa, '[');
                    try buf.appendSlice(gpa, p.index_key_name);
                    try buf.appendSlice(gpa, ": ");
                    if (std.mem.eql(u8, p.name, "[]L")) {
                        try buf.appendSlice(gpa, "Lowercase<string>");
                    } else if (std.mem.eql(u8, p.name, "[]U")) {
                        try buf.appendSlice(gpa, "Uppercase<string>");
                    } else if (p.index_key_is_number) {
                        try buf.appendSlice(gpa, "number");
                    } else {
                        try buf.appendSlice(gpa, "string");
                    }
                    try buf.appendSlice(gpa, "]: ");
                    try typeToStringInner(c, p.type_id, buf, depth + 1);
                }
                for (props) |p| {
                    if (std.mem.startsWith(u8, p.name, "[]")) continue;
                    if (!first) try buf.appendSlice(gpa, "; ");
                    first = false;
                    if (p.readonly) try buf.appendSlice(gpa, "readonly ");
                    if (needsPropertyQuoting(p.name)) {
                        const q: u8 = if (p.key_single_quoted) '\'' else '"';
                        try buf.append(gpa, q);
                        try buf.appendSlice(gpa, p.name);
                        try buf.append(gpa, q);
                    } else {
                        try buf.appendSlice(gpa, p.name);
                    }
                    const pv = c.store.get(p.type_id);
                    if (p.is_method and pv.kind == .function_t) {
                        // Render method shorthand: name(): T
                        const msigs = c.store.signaturesOf(pv.signatures);
                        if (p.optional) try buf.append(gpa, '?');
                        if (msigs.len == 1) {
                            const msig = msigs[0];
                            const mparams = c.store.signatureParamsOf(msig);
                            const mnames = c.store.signatureParamNamesOf(msig);
                            if (c.fn_type_params.get(p.type_id)) |tp_prefix|
                                try buf.appendSlice(gpa, tp_prefix);
                            try buf.append(gpa, '(');
                            const mopts = c.store.signatureParamOptionalsOf(msig);
                            for (mparams, 0..) |mp, mi| {
                                if (mi > 0) try buf.appendSlice(gpa, ", ");
                                const mis_rest = msig.rest_param_index != 0xFFFF and mi == msig.rest_param_index;
                                if (mis_rest) try buf.appendSlice(gpa, "...");
                                const mn = if (mi < mnames.len) mnames[mi] else "";
                                const mis_opt = !mis_rest and mi < mopts.len and mopts[mi];
                                if (mn.len > 0) {
                                    try buf.appendSlice(gpa, mn);
                                    if (mis_opt) try buf.append(gpa, '?');
                                    try buf.appendSlice(gpa, ": ");
                                }
                                try typeToStringInner(c, mp, buf, depth + 1);
                            }
                            try buf.appendSlice(gpa, "): ");
                            if (msig.predicate_param_index != 0xFFFF and msig.predicate_target != .none) {
                                const pred_name = if (msig.predicate_param_index == 0xFFFE) "this" else if (msig.predicate_param_index < mnames.len) mnames[msig.predicate_param_index] else "";
                                if (pred_name.len > 0) {
                                    if (msig.is_assertion) try buf.appendSlice(gpa, "asserts ");
                                    try buf.appendSlice(gpa, pred_name);
                                    try buf.appendSlice(gpa, " is ");
                                    try typeToStringInner(c, msig.predicate_target, buf, depth + 1);
                                } else {
                                    try typeToStringInner(c, msig.return_type, buf, depth + 1);
                                }
                            } else if (msig.is_assertion and msig.predicate_param_index != 0xFFFF) {
                                const pred_name = if (msig.predicate_param_index == 0xFFFE) "this" else if (msig.predicate_param_index < mnames.len) mnames[msig.predicate_param_index] else "";
                                if (pred_name.len > 0) {
                                    try buf.appendSlice(gpa, "asserts ");
                                    try buf.appendSlice(gpa, pred_name);
                                } else {
                                    try typeToStringInner(c, msig.return_type, buf, depth + 1);
                                }
                            } else {
                                try typeToStringInner(c, msig.return_type, buf, depth + 1);
                            }
                        } else {
                            // Multi-sig overloaded method: render each sig separately.
                            // The name + optional '?' for the first sig were already written.
                            for (msigs, 0..) |msig, msi| {
                                if (msi > 0) {
                                    try buf.appendSlice(gpa, "; ");
                                    if (p.readonly) try buf.appendSlice(gpa, "readonly ");
                                    if (needsPropertyQuoting(p.name)) {
                                        const q: u8 = if (p.key_single_quoted) '\'' else '"';
                                        try buf.append(gpa, q);
                                        try buf.appendSlice(gpa, p.name);
                                        try buf.append(gpa, q);
                                    } else {
                                        try buf.appendSlice(gpa, p.name);
                                    }
                                }
                                const sig_pool_idx_m: u32 = pv.signatures.start + @as(u32, @intCast(msi));
                                if (c.sig_type_params.get(sig_pool_idx_m)) |tp_prefix|
                                    try buf.appendSlice(gpa, tp_prefix);
                                try buf.append(gpa, '(');
                                const mparams = c.store.signatureParamsOf(msig);
                                const mnames = c.store.signatureParamNamesOf(msig);
                                const mopts = c.store.signatureParamOptionalsOf(msig);
                                for (mparams, 0..) |mp, mi| {
                                    if (mi > 0) try buf.appendSlice(gpa, ", ");
                                    const mis_rest = msig.rest_param_index != 0xFFFF and mi == msig.rest_param_index;
                                    if (mis_rest) try buf.appendSlice(gpa, "...");
                                    const mn = if (mi < mnames.len) mnames[mi] else "";
                                    const mis_opt = !mis_rest and mi < mopts.len and mopts[mi];
                                    if (mn.len > 0) {
                                        try buf.appendSlice(gpa, mn);
                                        if (mis_opt) try buf.append(gpa, '?');
                                        try buf.appendSlice(gpa, ": ");
                                    }
                                    try typeToStringInner(c, mp, buf, depth + 1);
                                }
                                try buf.appendSlice(gpa, "): ");
                                try typeToStringInner(c, msig.return_type, buf, depth + 1);
                            }
                        }
                    } else {
                        if (p.optional) try buf.append(gpa, '?');
                        try buf.appendSlice(gpa, ": ");
                        try typeToStringInner(c, p.type_id, buf, depth + 1);
                    }
                }
                try buf.appendSlice(gpa, "; }");
            }
        },
        .intersection_t => {
            // If tagged with a type-alias name, serialize as the alias
            // (e.g. `type T = A & B` at use site shows as `T`, not `A & B`).
            if (t.alias_name.len > 0) {
                try buf.appendSlice(gpa, t.alias_name);
                return;
            }
            for (c.store.idsOf(t.list_data), 0..) |m, i| {
                if (i > 0) try buf.appendSlice(gpa, " & ");
                try typeToStringInner(c, m, buf, depth + 1);
            }
        },
        .union_t => {
            // If tagged with a type-alias name AND the union contains at least
            // one complex member (not a bare primitive/literal), serialize as
            // the alias. TypeScript reports `All` for `type All = A | B` when
            // A/B are object/named types, but expands simple scalar unions like
            // `type MaybeStr = string | undefined` to `string | undefined`.
            // EXCEPTION: when all members are enum literals from the same enum,
            // output the enum name (e.g. `E.A | E.B` → `E`).
            const members_for_enum = c.store.idsOf(t.list_data);
            // Check if all members are enum literals (from one or more enums).
            // If so, collapse to enum name(s): `E.a | E.b | F.c` → `E | F`.
            const all_enum_members = blk: {
                if (members_for_enum.len == 0) break :blk false;
                for (members_for_enum) |m| {
                    if (c.store.get(m).enum_name.len == 0) break :blk false;
                }
                break :blk true;
            };
            if (all_enum_members) {
                if (t.alias_name.len > 0) {
                    try buf.appendSlice(gpa, t.alias_name);
                    return;
                }
                // Collect unique enum names in encounter order.
                var enum_names: [16][]const u8 = undefined;
                var n_enums: usize = 0;
                for (members_for_enum) |m| {
                    const ename = c.store.get(m).enum_name;
                    const already = for (enum_names[0..n_enums]) |en| {
                        if (std.mem.eql(u8, en, ename)) break true;
                    } else false;
                    if (!already and n_enums < enum_names.len) {
                        enum_names[n_enums] = ename;
                        n_enums += 1;
                    }
                }
                // A PARTIAL union of one enum's members stays expanded
                // (`E.A | E.B`, not `E`) — collapse only full coverage.
                const collapse = blk: {
                    if (n_enums != 1) break :blk true; // multi-enum: keep legacy collapse
                    const total = c.enumDeclMemberCount(enum_names[0]) orelse break :blk true;
                    break :blk members_for_enum.len >= total;
                };
                if (collapse) {
                    for (enum_names[0..n_enums], 0..) |en, i| {
                        if (i > 0) try buf.appendSlice(gpa, " | ");
                        try buf.appendSlice(gpa, en);
                    }
                    return;
                }
                // fall through to normal member-by-member rendering
            }
            if (t.alias_name.len > 0) {
                const members = c.store.idsOf(t.list_data);
                const has_complex = for (members) |m| {
                    const mk = c.store.get(m).kind;
                    switch (mk) {
                        .type_ref, .object_t, .function_t, .intersection_t,
                        .array_t, .readonly_array_t, .tuple_t, .type_param => break true,
                        else => {},
                    }
                } else false;
                const all_literals = members.len > 0 and for (members) |m| {
                    switch (c.store.get(m).kind) {
                        .string_literal, .number_literal, .boolean_literal => {},
                        else => break false,
                    }
                } else true;
                const all_non_nullish_prim = members.len > 2 and for (members) |m| {
                    switch (c.store.get(m).kind) {
                        .string, .number, .boolean, .bigint, .symbol => {},
                        else => break false,
                    }
                } else true;
                if (has_complex or all_literals or all_non_nullish_prim) {
                    try buf.appendSlice(gpa, t.alias_name);
                    return;
                }
            }
            const ids = c.store.idsOf(t.list_data);
            // Output union members in insertion order (matches tsc's declaration order),
            // deduped by rendered form — tsc collapses members that display identically
            // (e.g. two same-named type_refs distinguished only by symbol_scope).
            // Function types in a union need parens to distinguish `(() => T) | U`
            // from `() => T | U` (which reads as `() => (T | U)`).
            var seen: std.ArrayListUnmanaged([]const u8) = .empty;
            defer {
                for (seen.items) |s| gpa.free(s);
                seen.deinit(gpa);
            }
            for (ids) |m| {
                var mbuf: std.ArrayList(u8) = .empty;
                defer mbuf.deinit(gpa);
                const mt = c.store.get(m);
                // Function types in a union: `() => T | U` reads as `() => (T | U)`, so
                // wrap in parens: `(() => T) | U`. Likewise, intersection types `A & B | C`
                // parse ambiguously — tsc renders `(A & B) | C`.
                const needs_parens = mt.alias_name.len == 0 and
                    ((mt.kind == .function_t and !mt.is_overload_set) or
                     mt.kind == .intersection_t);
                if (needs_parens) try mbuf.appendSlice(gpa, "(");
                try typeToStringInner(c, m, &mbuf, depth + 1);
                if (needs_parens) try mbuf.appendSlice(gpa, ")");
                var dup = false;
                for (seen.items) |s| {
                    if (std.mem.eql(u8, s, mbuf.items)) { dup = true; break; }
                }
                if (dup) continue;
                if (seen.items.len > 0) try buf.appendSlice(gpa, " | ");
                try buf.appendSlice(gpa, mbuf.items);
                try seen.append(gpa, try gpa.dupe(u8, mbuf.items));
            }
        },
    }
}

/// Returns true when a property key must be quoted in type display output.
/// Valid JS identifiers and non-negative integer literals are unquoted; anything
/// else (hyphens, dots, spaces, leading digits, etc.) needs double-quotes.
fn needsPropertyQuoting(name: []const u8) bool {
    if (name.len == 0) return true;
    // Late-bound computed key (`[x]`, `[Symbol.iterator]`) — rendered verbatim.
    if (name[0] == '[' and name[name.len - 1] == ']') return false;
    // tsc renders a property key unquoted iff it is a CANONICAL numeric-literal
    // name: `(+name).toString() === name`. So "0"/"100"/"1.5" are unquoted, but
    // "1.0", "1.", "007", "0.0" (non-canonical) stay quoted. We only consider the
    // numeric path when the name begins with a digit or '.' (leading '-' / other
    // forms keep their current quoted behavior). A valid identifier can never
    // start with a digit, so there is no conflict with the identifier check.
    if ((name[0] >= '0' and name[0] <= '9') or name[0] == '.') {
        const f = std.fmt.parseFloat(f64, name) catch return true;
        var buf: [64]u8 = undefined;
        const canon = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return true;
        return !std.mem.eql(u8, canon, name);
    }
    // Valid identifier: [a-zA-Z_$][a-zA-Z0-9_$]*
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_' and first != '$') return true;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return true;
    }
    return false;
}
