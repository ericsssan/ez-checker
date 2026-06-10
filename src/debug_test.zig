const std = @import("std");
const parser = @import("es_parser");
const Checker = @import("ez_checker").Checker;
const NodeIndex = parser.ast.NodeIndex;

test "assignment narrowing reads" {
    const gpa = std.testing.allocator;
    const src =
        \\var x = true;
        \\var a;
        \\a = x;
        \\var y = 5;
        \\var b = y;
        \\x = false;
        \\var c = x;
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
        if (ast.nodeTag(ni) != .identifier) continue;
        const span = ast.nodeSpan(ni);
        if (span.end > src.len or span.end <= span.start) continue;
        const text = src[span.start..span.end];
        const line = std.mem.count(u8, src[0..span.start], "\n");
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        std.debug.print("L{d} '{s}' = {s}\n", .{ line, text, tystr });
    }
}
