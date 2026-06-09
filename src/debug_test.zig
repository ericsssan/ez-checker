const std = @import("std");
const parser = @import("es_parser");
const Checker = @import("root.zig").Checker;
const NodeIndex = parser.NodeIndex;

test "debug getName" {
    const gpa = std.testing.allocator;
    const src =
        \\class Bug {
        \\  getName():string {
        \\    return "name";
        \\  }
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
        const tag = ast.nodeTag(ni);
        const span = ast.nodeSpan(ni);
        if (span.end <= span.start or span.end > src.len) { n += 1; continue; }
        const text = src[span.start..span.end];
        if (!std.mem.eql(u8, text, "getName")) continue;
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        const pidx = if (n < sem.parent_indices.len) sem.parent_indices[n] else 0xFFFFFFFF;
        const ptag = if (pidx != 0xFFFFFFFF and pidx != @as(u32, @intFromEnum(NodeIndex.none)))
            ast.nodeTag(@enumFromInt(pidx)) else .none;
        std.debug.print("n={d} tag={s} text='{s}' ty='{s}' parent_tag={s}\n",
            .{n, @tagName(tag), text, tystr, @tagName(ptag)});
    }
}
