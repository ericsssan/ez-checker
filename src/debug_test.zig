const std = @import("std");
const parser = @import("es_parser");
const Checker = @import("ez_checker").Checker;
const NodeIndex = parser.ast.NodeIndex;

test "class in namespace this members" {
    const gpa = std.testing.allocator;
    const src =
        \\module TypeScript {
        \\    export class Stack {
        \\        public top: number = 0;
        \\        public count(): number {
        \\            return this.top + 1;
        \\        }
        \\    }
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
        if (ast.nodeTag(ni) != .member_expr and ast.nodeTag(ni) != .this_expr) continue;
        const span = ast.nodeSpan(ni);
        if (span.end > src.len) continue;
        const text = if (span.end > span.start) src[span.start..span.end] else "<>";
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        std.debug.print("node {d} tag={s} text='{s}' ty='{s}'\n", .{ n, @tagName(ast.nodeTag(ni)), text, tystr });
    }
}
