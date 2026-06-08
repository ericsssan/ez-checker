//! Per-line / per-fn rule suppressions parsed from source comments.
//!
//! Syntax:
//!
//!   // zbc-disable-line: rule-id              — suppresses `rule-id`
//!                                                on the SAME source line
//!   // zbc-disable-next-line: rule-id         — suppresses `rule-id`
//!                                                on the NEXT non-comment
//!                                                line
//!   // zbc-disable-line: rule-id, rule-id2    — comma-separated list
//!   // zbc-disable-line: *                    — suppresses ALL rules
//!
//! Rationale: zbc's analysis is purely inferred.  The author has no
//! way to override the inferred belief by asserting alternative
//! semantics — the only override is to silence a specific finding
//! via this suppression mechanism.
//!
//! Implementation note: Zig's tokenizer DROPS line comments before
//! producing the token stream, so this scanner walks the raw source
//! string directly rather than `tree.tokens`.

const std = @import("std");
const Ast = std.zig.Ast;

/// A single suppression record.  Owned by the Suppressions storage.
pub const Entry = struct {
    /// 1-indexed source line the suppression applies to.
    line: u32,
    /// Rule id to suppress.  Empty string means "all rules" (the `*`
    /// wildcard).
    rule_id: []const u8,
};

pub const Suppressions = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,

    pub fn deinit(self: *Suppressions) void {
        self.arena.deinit();
    }

    /// True iff `rule_id` is suppressed on the given 1-indexed `line`.
    pub fn isSuppressed(self: *const Suppressions, rule_id: []const u8, line: u32) bool {
        for (self.entries) |e| {
            if (e.line != line) continue;
            if (e.rule_id.len == 0) return true; // wildcard
            if (std.mem.eql(u8, e.rule_id, rule_id)) return true;
        }
        return false;
    }
};

/// Parse all `// zbc-disable-*` comments in `source`.  Caller owns
/// the returned Suppressions; deinit drops the arena that backs
/// every interior slice.
pub fn parse(gpa: std.mem.Allocator, source: []const u8) !Suppressions {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var entries: std.ArrayListUnmanaged(Entry) = .empty;

    var line_no: u32 = 1;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line_no += 1;
            continue;
        }
        // Look for `// zbc-disable` — minimal prefix.  Match
        // case-sensitively; require either `// ` or `//\t` etc.
        if (i + 1 >= source.len) break;
        if (source[i] != '/' or source[i + 1] != '/') continue;
        // Skip the `//`.
        const after_slashes = i + 2;
        // Trim a single leading space for the most common shape.
        const start: usize = if (after_slashes < source.len and source[after_slashes] == ' ')
            after_slashes + 1
        else
            after_slashes;
        if (start >= source.len) break;
        // Read to end of line.
        var eol: usize = start;
        while (eol < source.len and source[eol] != '\n') : (eol += 1) {}
        const body = source[start..eol];

        const directive = parseDirective(body) orelse {
            // Not a zbc-disable comment — skip to end of line so we
            // don't re-scan inside the comment body.
            // Use eol - 1 so the outer `i += 1` lands on the '\n' and
            // triggers the line_no increment (eol points to '\n' or EOF).
            i = if (eol > 0) eol - 1 else eol;
            continue;
        };

        const target_line: u32 = switch (directive.kind) {
            .same_line => line_no,
            .next_line => line_no + 1,
        };

        // Split the comma-separated rule list.
        var it = std.mem.splitScalar(u8, directive.list, ',');
        while (it.next()) |raw| {
            // Trim surrounding whitespace, then drop any trailing annotation
            // (e.g. "rule-id — explanation" or "rule-id  # note") by stopping
            // at the first whitespace character inside the token.
            const trimmed = std.mem.trim(u8, raw, " \t");
            const id = if (std.mem.indexOfAny(u8, trimmed, " \t")) |ws|
                trimmed[0..ws]
            else
                trimmed;
            if (id.len == 0) continue;
            const stored: []const u8 = if (std.mem.eql(u8, id, "*"))
                ""
            else
                try a.dupe(u8, id);
            try entries.append(a, .{ .line = target_line, .rule_id = stored });
        }
        i = if (eol > 0) eol - 1 else eol;
    }

    return .{
        .arena = arena,
        .entries = try entries.toOwnedSlice(a),
    };
}

const DirectiveKind = enum { same_line, next_line };
const ParsedDirective = struct {
    kind: DirectiveKind,
    /// The rule-id list (comma-separated; pre-trim).
    list: []const u8,
};

fn parseDirective(comment_body: []const u8) ?ParsedDirective {
    const trimmed = std.mem.trim(u8, comment_body, " \t");
    inline for (.{
        .{ "zbc-disable-next-line:", DirectiveKind.next_line },
        .{ "zbc-disable-line:", DirectiveKind.same_line },
    }) |pair| {
        const prefix: []const u8 = pair[0];
        const kind: DirectiveKind = pair[1];
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            return .{ .kind = kind, .list = trimmed[prefix.len..] };
        }
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────

const testing = std.testing;

test "parse: zbc-disable-line on same line" {
    var s = try parse(testing.allocator,
        \\fn f() void {
        \\    _ = 1; // zbc-disable-line: my-rule
        \\}
    );
    defer s.deinit();
    try testing.expect(s.isSuppressed("my-rule", 2));
    try testing.expect(!s.isSuppressed("my-rule", 1));
    try testing.expect(!s.isSuppressed("other-rule", 2));
}

test "parse: zbc-disable-next-line targets the next line" {
    var s = try parse(testing.allocator,
        \\fn f() void {
        \\    // zbc-disable-next-line: my-rule
        \\    _ = 1;
        \\}
    );
    defer s.deinit();
    try testing.expect(s.isSuppressed("my-rule", 3));
    try testing.expect(!s.isSuppressed("my-rule", 2));
}

test "parse: wildcard suppresses any rule" {
    var s = try parse(testing.allocator,
        \\fn f() void {
        \\    _ = 1; // zbc-disable-line: *
        \\}
    );
    defer s.deinit();
    try testing.expect(s.isSuppressed("any-rule", 2));
    try testing.expect(s.isSuppressed("other-rule", 2));
}

test "parse: comma-separated rule ids" {
    var s = try parse(testing.allocator,
        \\_ = 1; // zbc-disable-line: rule-a, rule-b , rule-c
    );
    defer s.deinit();
    try testing.expect(s.isSuppressed("rule-a", 1));
    try testing.expect(s.isSuppressed("rule-b", 1));
    try testing.expect(s.isSuppressed("rule-c", 1));
    try testing.expect(!s.isSuppressed("rule-d", 1));
}

test "parse: unrelated comments are ignored" {
    var s = try parse(testing.allocator,
        \\// just a regular comment
        \\fn f() void {
        \\    _ = 1; // another regular comment
        \\}
    );
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), s.entries.len);
}

test "parse: empty source" {
    var s = try parse(testing.allocator, "");
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), s.entries.len);
}

test "parse: line_no not skewed by leading non-zbc comments" {
    // Each `// comment` line was previously consuming the '\n' without
    // incrementing line_no, causing stored suppression lines to drift.
    var s = try parse(testing.allocator,
        \\// comment line 1
        \\// comment line 2
        \\// comment line 3
        \\fn f(buf: []const u8, x: usize) u8 {
        \\    return buf[x - 1]; // zbc-disable-line: index-minus-one-without-zero-guard
        \\}
    );
    defer s.deinit();
    // The directive is on line 5; must not be stored as line 2 (drift of 3).
    try testing.expect(s.isSuppressed("index-minus-one-without-zero-guard", 5));
    try testing.expect(!s.isSuppressed("index-minus-one-without-zero-guard", 2));
}

test "parse: trailing annotation after rule-id is ignored" {
    var s = try parse(testing.allocator,
        \\_ = x; // zbc-disable-line: my-rule — this is safe because reasons
    );
    defer s.deinit();
    try testing.expect(s.isSuppressed("my-rule", 1));
    try testing.expect(!s.isSuppressed("my-rule — this is safe because reasons", 1));
}

test "parse: trailing annotation does not bleed into next comma-token" {
    var s = try parse(testing.allocator,
        \\_ = x; // zbc-disable-line: rule-a — note, rule-b
    );
    defer s.deinit();
    try testing.expect(s.isSuppressed("rule-a", 1));
    try testing.expect(s.isSuppressed("rule-b", 1));
    try testing.expect(!s.isSuppressed("rule-a — note", 1));
}
