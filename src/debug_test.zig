const std = @import("std");
const parser = @import("es_parser");
const Checker = @import("ez_checker").Checker;
const NodeIndex = parser.ast.NodeIndex;

test "debug default param optional" {
    const gpa = std.testing.allocator;
    const src = "function foo(x = 1) { }";
    var lex = try parser.Lexer.tokenize(gpa, src);
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

    // Print type of foo
    var n: u32 = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: NodeIndex = @enumFromInt(n);
        const span = ast.nodeSpan(ni);
        if (span.end <= span.start or span.end > src.len) continue;
        const text = src[span.start..span.end];
        if (!std.mem.eql(u8, text, "foo")) continue;
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer std.testing.allocator.free(tystr);
        std.debug.print("text='{s}' tag={s} ty='{s}'\n",
            .{text, @tagName(ast.nodeTag(ni)), tystr});
    }
}
