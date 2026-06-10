const std = @import("std");
const parser = @import("es_parser");
const Checker = @import("ez_checker").Checker;
const NodeIndex = parser.ast.NodeIndex;

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
