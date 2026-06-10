const std = @import("std");
const parser = @import("es_parser");
const Checker = @import("ez_checker").Checker;
const NodeIndex = parser.ast.NodeIndex;

test "setter rest param" {
    const gpa = std.testing.allocator;
    const src =
        \\class C {
        \\    set X(...v) { }
        \\}
        \\function f(...args) { return args; }
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
        const span = ast.nodeSpan(ni);
        if (span.end > src.len or span.end <= span.start) continue;
        const text = src[span.start..span.end];
        if (!std.mem.eql(u8, text, "v") and !std.mem.eql(u8, text, "args") and !std.mem.eql(u8, text, "...v")) continue;
        const parents = sem.parent_indices;
        const pidx = parents[n];
        var ptag: []const u8 = "none";
        var gtag: []const u8 = "none";
        if (pidx != @intFromEnum(NodeIndex.none)) {
            ptag = @tagName(ast.nodeTag(@enumFromInt(pidx)));
            const gidx = parents[pidx];
            if (gidx != @intFromEnum(NodeIndex.none)) gtag = @tagName(ast.nodeTag(@enumFromInt(gidx)));
        }
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        std.debug.print("node {d} tag={s} parent={s} gp={s} text='{s}' ty='{s}'\n", .{ n, @tagName(ast.nodeTag(ni)), ptag, gtag, text, tystr });
    }
}
