const std = @import("std");
const parser = @import("es_parser");
const Checker = @import("ez_checker").Checker;
const NodeIndex = parser.ast.NodeIndex;

test "jsdoc type cast" {
    const gpa = std.testing.allocator;
    // Simpler: just the let with @type annotation, no function context
    const src =
        \\/** @type {'a' | 'b'} */
        \\let a = 'x';
        \\a;
    ;
    var lex = try parser.Lexer.tokenizeWithLanguage(gpa, src, .js);
    defer lex.deinit(gpa);
    var tokens = lex.tokens;
    var ast = try parser.Parser.parseWithLanguage(gpa, src, tokens.slice(), .js, true);
    defer ast.deinit(gpa);
    var sem = try parser.semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(gpa);
    var checker = try Checker.init(gpa, &ast, &sem, .{ .is_js_file = true });
    defer checker.deinit();

    // Print all nodes to understand structure
    std.debug.print("=== jsdoc test nodes ===\n", .{});
    var n: u32 = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: NodeIndex = @enumFromInt(n);
        const span = ast.nodeSpan(ni);
        if (span.end > src.len or span.end <= span.start) continue;
        const text = src[span.start..@min(span.end, span.start + 20)];
        const pidx = if (ni.toInt() < sem.parent_indices.len) sem.parent_indices[ni.toInt()] else 0xFFFF;
        std.debug.print("J node {d}: tag={s} parent={d} text='{s}'\n", .{
            n, @tagName(ast.nodeTag(ni)), pidx, text,
        });
    }

    n = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: NodeIndex = @enumFromInt(n);
        const tag = ast.nodeTag(ni);
        const span = ast.nodeSpan(ni);
        if (span.end > src.len or span.end <= span.start) continue;
        const text = src[span.start..span.end];
        if (!std.mem.eql(u8, text, "a") and !std.mem.eql(u8, text, "'x'")) continue;
        if (tag != .identifier and tag != .string_literal) continue;
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        const pidx = if (ni.toInt() < sem.parent_indices.len) sem.parent_indices[ni.toInt()] else 0xFFFF;
        std.debug.print("node {d} '{s}' (tag={s}) parent={d}(tag={s}) = {s}\n", .{
            n, text, @tagName(tag),
            pidx,
            if (pidx < ast.nodes.len) @tagName(ast.nodeTag(@enumFromInt(pidx))) else "?",
            tystr,
        });
    }
}

test "catch clause type annotation" {
    const gpa = std.testing.allocator;
    // Matches catchClauseWithTypeAnnotation.ts structure: catch params inside a function
    // with var redeclarations in later catch bodies
    const src =
        \\function fn(x: boolean) {
        \\  try { } catch (x) { }
        \\  try { } catch (x: any) { }
        \\  try { } catch (x: unknown) { }
        \\  try { } catch (x: Error) { }
        \\  try { } catch (x) { var x: string; }
        \\  try { } catch (x) { var x: boolean; }
        \\}
    ;
    var lex = try parser.Lexer.tokenizeWithLanguage(gpa, src, .ts);
    defer lex.deinit(gpa);
    var tokens = lex.tokens;
    var ast = try parser.Parser.parseWithLanguage(gpa, src, tokens.slice(), .ts, true);
    defer ast.deinit(gpa);
    var sem = try parser.semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(gpa);
    var checker = try Checker.init(gpa, &ast, &sem, .{});
    defer checker.deinit();

    var n: u32 = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: NodeIndex = @enumFromInt(n);
        const tag = ast.nodeTag(ni);
        if (tag != .identifier) continue;
        const span = ast.nodeSpan(ni);
        if (span.end > src.len or span.end <= span.start) continue;
        const text = src[span.start..span.end];
        if (!std.mem.startsWith(u8, text, "x")) continue;
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        const data = ast.nodeData(ni);
        const parent_idx = if (ni.toInt() < sem.parent_indices.len) sem.parent_indices[ni.toInt()] else 0xFFFF;
        std.debug.print("node {d} '{s}' (tag={s}) rhs={d} parent={d}(tag={s}) = {s}\n", .{
            n, text, @tagName(tag),
            @intFromEnum(data.rhs),
            parent_idx,
            if (parent_idx < ast.nodes.len) @tagName(ast.nodeTag(@enumFromInt(parent_idx))) else "?",
            tystr,
        });
    }
}

test "computed enum members" {
    const gpa = std.testing.allocator;
    const src =
        \\declare function computed(x: number): number;
        \\enum E {
        \\    A = computed(0),
        \\    B = computed(1),
        \\    C = computed(2),
        \\    D = computed(3),
        \\}
        \\function f1() {
        \\    const c1 = E.B;
        \\    let v1 = c1;
        \\    return v1;
        \\}
    ;
    var lex = try parser.Lexer.tokenizeWithLanguage(gpa, src, .ts);
    defer lex.deinit(gpa);
    var tokens = lex.tokens;
    var ast = try parser.Parser.parseWithLanguage(gpa, src, tokens.slice(), .ts, true);
    defer ast.deinit(gpa);
    var sem = try parser.semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(gpa);
    var checker = try Checker.init(gpa, &ast, &sem, .{});
    defer checker.deinit();

    var n: u32 = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: NodeIndex = @enumFromInt(n);
        if (ast.nodeTag(ni) != .identifier and ast.nodeTag(ni) != .member_expr) continue;
        const span = ast.nodeSpan(ni);
        if (span.end > src.len or span.end <= span.start) continue;
        const text = src[span.start..span.end];
        const want = std.mem.eql(u8, text, "c1") or std.mem.eql(u8, text, "v1") or std.mem.eql(u8, text, "B") or std.mem.eql(u8, text, "E.B");
        if (!want) continue;
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        std.debug.print("node {d} '{s}' = {s}\n", .{ n, text, tystr });
    }
}

test "SKIP contextual literal preservation in call arg" {
    const gpa = std.testing.allocator;
    const src =
        \\interface X { type: 'x'; value: string; }
        \\interface Y { type: 'y'; value: 'none' | 'done'; }
        \\function foo(bar: X | Y) { }
        \\foo({ type: 'y', value: 'done' });
    ;
    var lex = try @import("es_parser").Lexer.tokenizeWithLanguage(gpa, src, .ts);
    defer lex.deinit(gpa);
    var tokens = lex.tokens;
    var ast = try @import("es_parser").Parser.parseWithLanguage(gpa, src, tokens.slice(), .ts, true);
    defer ast.deinit(gpa);
    var sem = try @import("es_parser").semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(gpa);
    var checker = try @import("ez_checker").Checker.init(gpa, &ast, &sem, .{});
    defer checker.deinit();

    var n: u32 = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: @import("es_parser").ast.NodeIndex = @enumFromInt(n);
        const tag = ast.nodeTag(ni);
        if (tag != .identifier and tag != .string_literal) continue;
        const span = ast.nodeSpan(ni);
        if (span.end > src.len or span.end <= span.start) continue;
        const text = src[span.start..span.end];
        if (!std.mem.eql(u8, text, "type") and !std.mem.eql(u8, text, "value") and
            !std.mem.eql(u8, text, "'y'") and !std.mem.eql(u8, text, "'done'")) continue;
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        std.debug.print("node {d} '{s}' (tag={s}) = {s}\n", .{ n, text, @tagName(tag), tystr });
    }
}

test "SKIP contextual literal - full oracle sweep" {
    const gpa = std.testing.allocator;
    const src =
        \\interface X { type: 'x'; value: string; }
        \\interface Y { type: 'y'; value: 'none' | 'done'; }
        \\function foo(bar: X | Y) { }
        \\foo({ type: 'y', value: 'done' });
    ;
    var lex = try @import("es_parser").Lexer.tokenizeWithLanguage(gpa, src, .ts);
    defer lex.deinit(gpa);
    var tokens = lex.tokens;
    var ast = try @import("es_parser").Parser.parseWithLanguage(gpa, src, tokens.slice(), .ts, true);
    defer ast.deinit(gpa);
    var sem = try @import("es_parser").semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(gpa);
    var checker = try @import("ez_checker").Checker.init(gpa, &ast, &sem, .{});
    defer checker.deinit();

    // Simulate oracle: sweep ALL nodes first (this caches callees etc)
    var n: u32 = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: @import("es_parser").ast.NodeIndex = @enumFromInt(n);
        _ = checker.typeOf(ni);
    }

    // Now check specific nodes
    n = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: @import("es_parser").ast.NodeIndex = @enumFromInt(n);
        const tag = ast.nodeTag(ni);
        if (tag != .identifier) continue;
        const span = ast.nodeSpan(ni);
        if (span.end > src.len or span.end <= span.start) continue;
        const text = src[span.start..span.end];
        if (!std.mem.eql(u8, text, "type") and !std.mem.eql(u8, text, "value")) continue;
        // Only property key identifiers (check parent is .property)
        const parents = sem.parent_indices;
        if (ni.toInt() >= parents.len) continue;
        const pidx = parents[ni.toInt()];
        if (pidx == @intFromEnum(@import("es_parser").ast.NodeIndex.none)) continue;
        const par: @import("es_parser").ast.NodeIndex = @enumFromInt(pidx);
        if (ast.nodeTag(par) != .property) continue;
        const pdata = ast.nodeData(par);
        if (pdata.lhs != ni) continue;
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        std.debug.print("(full sweep) node {d} '{s}' = {s}\n", .{ n, text, tystr });
    }
}

test "interface literal property type" {
    const gpa = std.testing.allocator;
    const src =
        \\interface I {
        \\    a: "a";
        \\}
        \\let i: I;
        \\i = { ...{ a: "a" } };
    ;
    var lex = try parser.Lexer.tokenizeWithLanguage(gpa, src, .ts);
    defer lex.deinit(gpa);
    var tokens = lex.tokens;
    var ast = try parser.Parser.parseWithLanguage(gpa, src, tokens.slice(), .ts, true);
    defer ast.deinit(gpa);
    var sem = try parser.semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(gpa);
    var checker = try Checker.init(gpa, &ast, &sem, .{});
    defer checker.deinit();

    // Warm up
    var n: u32 = 1;
    while (n < ast.nodes.len) : (n += 1) {
        _ = checker.typeOf(@enumFromInt(n));
    }

    n = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: NodeIndex = @enumFromInt(n);
        const tag = ast.nodeTag(ni);
        if (tag != .identifier and tag != .string_literal) continue;
        const span = ast.nodeSpan(ni);
        if (span.end > src.len or span.end <= span.start) continue;
        const text = src[span.start..span.end];
        if (!std.mem.eql(u8, text, "a") and !std.mem.eql(u8, text, "\"a\"")) continue;
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        const pidx = if (ni.toInt() < sem.parent_indices.len) sem.parent_indices[ni.toInt()] else 0xFFFF;
        std.debug.print("node {d} '{s}' (tag={s}) parent={d}(tag={s}) = {s}\n", .{
            n, text, @tagName(tag),
            pidx,
            if (pidx < ast.nodes.len) @tagName(ast.nodeTag(@enumFromInt(pidx))) else "?",
            tystr,
        });
    }
}

test "tuple destructuring with annotation" {
    const gpa = std.testing.allocator;
    const src =
        \\type RexOrRaptor = "t-rex" | "raptor";
        \\let [im, a, dinosaur]: ["I'm", "a", RexOrRaptor] = ["I'm", "a", "t-rex"];
    ;
    // Debug: print ALL node tags and parents
    {
        var lex2 = try parser.Lexer.tokenizeWithLanguage(gpa, src, .ts);
        defer lex2.deinit(gpa);
        var tokens2 = lex2.tokens;
        var ast2 = try parser.Parser.parseWithLanguage(gpa, src, tokens2.slice(), .ts, true);
        defer ast2.deinit(gpa);
        var sem2 = try parser.semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast2, .{
            .is_module = true,
            .build_parents = true,
        });
        defer sem2.deinit(gpa);
        std.debug.print("=== AST nodes ===\n", .{});
        var n2: u32 = 1;
        while (n2 < ast2.nodes.len) : (n2 += 1) {
            const ni2: NodeIndex = @enumFromInt(n2);
            const span2 = ast2.nodeSpan(ni2);
            const text2 = if (span2.end <= src.len and span2.end > span2.start)
                src[span2.start..@min(span2.end, span2.start + 20)]
            else
                "?";
            const pidx2 = if (n2 < sem2.parent_indices.len) sem2.parent_indices[n2] else 0xFFFF;
            std.debug.print("n{d}: tag={s} parent={d}({s}) text='{s}'\n", .{
                n2, @tagName(ast2.nodeTag(ni2)), pidx2,
                if (pidx2 < ast2.nodes.len) @tagName(ast2.nodeTag(@enumFromInt(pidx2))) else "?",
                text2,
            });
        }
    }
    var lex = try parser.Lexer.tokenizeWithLanguage(gpa, src, .ts);
    defer lex.deinit(gpa);
    var tokens = lex.tokens;
    var ast = try parser.Parser.parseWithLanguage(gpa, src, tokens.slice(), .ts, true);
    defer ast.deinit(gpa);
    var sem = try parser.semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(gpa);
    var checker = try Checker.init(gpa, &ast, &sem, .{});
    defer checker.deinit();

    // Warm up
    var n: u32 = 1;
    while (n < ast.nodes.len) : (n += 1) {
        _ = checker.typeOf(@enumFromInt(n));
    }

    n = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: NodeIndex = @enumFromInt(n);
        const tag = ast.nodeTag(ni);
        if (tag != .identifier) continue;
        const span = ast.nodeSpan(ni);
        if (span.end > src.len or span.end <= span.start) continue;
        const text = src[span.start..span.end];
        if (!std.mem.eql(u8, text, "a") and !std.mem.eql(u8, text, "im") and
            !std.mem.eql(u8, text, "dinosaur")) continue;
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        const pidx = if (ni.toInt() < sem.parent_indices.len) sem.parent_indices[ni.toInt()] else 0xFFFF;
        std.debug.print("node {d} '{s}' (tag={s}) parent={d}(tag={s}) = {s}\n", .{
            n, text, @tagName(tag),
            pidx,
            if (pidx < ast.nodes.len) @tagName(ast.nodeTag(@enumFromInt(pidx))) else "?",
            tystr,
        });
    }
}

test "SKIP contextual literal - node ordering" {
    const gpa = std.testing.allocator;
    const src =
        \\interface X { type: 'x'; value: string; }
        \\interface Y { type: 'y'; value: 'none' | 'done'; }
        \\function foo(bar: X | Y) { }
        \\foo({ type: 'y', value: 'done' });
    ;
    var lex = try @import("es_parser").Lexer.tokenizeWithLanguage(gpa, src, .ts);
    defer lex.deinit(gpa);
    var tokens = lex.tokens;
    var ast = try @import("es_parser").Parser.parseWithLanguage(gpa, src, tokens.slice(), .ts, true);
    defer ast.deinit(gpa);
    var sem = try @import("es_parser").semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(gpa);

    // Print all nodes near the call expression to understand ordering
    var n: u32 = 30;
    while (n < ast.nodes.len and n <= 55) : (n += 1) {
        const ni: @import("es_parser").ast.NodeIndex = @enumFromInt(n);
        const span = ast.nodeSpan(ni);
        if (span.end <= span.start or span.end > src.len) {
            std.debug.print("node {d}: tag={s} (no span)\n", .{ n, @tagName(ast.nodeTag(ni)) });
            continue;
        }
        const text = src[span.start..@min(span.end, span.start + 40)];
        // strip newlines
        var buf: [80]u8 = undefined;
        var w: usize = 0;
        for (text) |ch| {
            if (ch != '\n' and ch != '\r' and w < buf.len - 1) { buf[w] = ch; w += 1; }
        }
        std.debug.print("node {d}: tag={s} text='{s}'\n", .{ n, @tagName(ast.nodeTag(ni)), buf[0..w] });
    }
}

test "SKIP contextual literal - full node listing" {
    const gpa = std.testing.allocator;
    const src =
        \\interface X { type: 'x'; value: string; }
        \\interface Y { type: 'y'; value: 'none' | 'done'; }
        \\function foo(bar: X | Y) { }
        \\foo({ type: 'y', value: 'done' });
    ;
    var lex = try @import("es_parser").Lexer.tokenizeWithLanguage(gpa, src, .ts);
    defer lex.deinit(gpa);
    var tokens = lex.tokens;
    var ast = try @import("es_parser").Parser.parseWithLanguage(gpa, src, tokens.slice(), .ts, true);
    defer ast.deinit(gpa);
    var sem = try @import("es_parser").semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(gpa);

    std.debug.print("total nodes: {d}\n", .{ast.nodes.len});
    var n: u32 = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: @import("es_parser").ast.NodeIndex = @enumFromInt(n);
        const span = ast.nodeSpan(ni);
        var text_buf: [30]u8 = undefined;
        var text_len: usize = 0;
        if (span.end > span.start and span.end <= src.len) {
            for (src[span.start..@min(span.end, span.start+30)]) |ch| {
                if (ch != '\n' and ch != '\r' and text_len < text_buf.len-1) { text_buf[text_len] = ch; text_len += 1; }
            }
        }
        // parent
        const pidx = if (ni.toInt() < sem.parent_indices.len) sem.parent_indices[ni.toInt()] else 0xFFFFFFFF;
        std.debug.print("node {d}: tag={s} parent={d} text='{s}'\n", .{ n, @tagName(ast.nodeTag(ni)), pidx, text_buf[0..text_len] });
    }
}

test "SKIP contextual literal - trace node 35" {
    const gpa = std.testing.allocator;
    const src =
        \\interface X { type: 'x'; value: string; }
        \\interface Y { type: 'y'; value: 'none' | 'done'; }
        \\function foo(bar: X | Y) { }
        \\foo({ type: 'y', value: 'done' });
    ;
    var lex = try @import("es_parser").Lexer.tokenizeWithLanguage(gpa, src, .ts);
    defer lex.deinit(gpa);
    var tokens = lex.tokens;
    var ast = try @import("es_parser").Parser.parseWithLanguage(gpa, src, tokens.slice(), .ts, true);
    defer ast.deinit(gpa);
    var sem = try @import("es_parser").semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(gpa);
    var checker = try @import("ez_checker").Checker.init(gpa, &ast, &sem, .{});
    defer checker.deinit();

    // Type nodes 0..34 first (simulating oracle sweep up to but not including 35)
    var n: u32 = 1;
    while (n <= 34) : (n += 1) {
        const ni: @import("es_parser").ast.NodeIndex = @enumFromInt(n);
        _ = checker.typeOf(ni);
    }

    // Check what's cached at callee node 34
    const callee_cached = checker.node_types[34];
    std.debug.print("node 34 (callee foo) cached type id: {d}\n", .{callee_cached.toInt()});

    // Now type the property key
    const ni35: @import("es_parser").ast.NodeIndex = @enumFromInt(35);
    const ty35 = checker.typeOf(ni35);
    const s35 = try checker.typeToString(ty35);
    defer gpa.free(s35);
    std.debug.print("node 35 'type' = {s}\n", .{s35});
}
