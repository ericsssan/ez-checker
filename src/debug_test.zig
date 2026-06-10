const std = @import("std");
const parser = @import("es_parser");
const Checker = @import("ez_checker").Checker;
const NodeIndex = parser.ast.NodeIndex;

test "setter pairs with getter" {
    const gpa = std.testing.allocator;
    const src =
        \\class Base {
        \\    get PublicPublic() { return 0; }
        \\    set PublicPublic(v) { return; }
        \\}
    ;
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

    var n: u32 = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: NodeIndex = @enumFromInt(n);
        const span = ast.nodeSpan(ni);
        if (span.end <= span.start or span.end > src.len) continue;
        const text = src[span.start..span.end];
        if (!std.mem.eql(u8, text, "v") and !std.mem.eql(u8, text, "PublicPublic")) continue;
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        const dty = checker.declaredTypeAtBinding(ni);
        const dtystr = try checker.typeToString(dty);
        defer gpa.free(dtystr);
        std.debug.print("node {d} tag={s} text='{s}' ty='{s}' declAt='{s}'\n", .{ n, @tagName(ast.nodeTag(ni)), text, tystr, dtystr });
    }
}
