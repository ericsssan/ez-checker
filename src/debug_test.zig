const std = @import("std");
const parser = @import("es_parser");
const Checker = @import("ez_checker").Checker;
const NodeIndex = parser.ast.NodeIndex;

test "debug optional param in interface method" {
    const gpa = std.testing.allocator;
    // Use a ts_interface_decl-style source that the oracle would process
    const src =
        \\interface IPromise3<T> {
        \\    then<U>(success?: (value: T) => U): IPromise3<U>;
        \\}
        \\declare var p1: IPromise3<string>;
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

    // Print ALL nodes
    var n: u32 = 1;
    while (n < ast.nodes.len) : (n += 1) {
        const ni: NodeIndex = @enumFromInt(n);
        const span = ast.nodeSpan(ni);
        const text = if (span.end > span.start and span.end <= src.len)
            src[span.start..@min(span.end, span.start + 30)]
        else
            "<empty>";
        std.debug.print("node[{d}] tag={s} text='{s}'\n",
            .{n, @tagName(ast.nodeTag(ni)), text});
    }
    std.debug.print("\n\nFound p1 type:\n", .{});
    for (1..ast.nodes.len) |ni_| {
        const ni: NodeIndex = @enumFromInt(ni_);
        const span = ast.nodeSpan(ni);
        if (span.end <= span.start or span.end > src.len) continue;
        const text = src[span.start..span.end];
        if (!std.mem.eql(u8, text, "p1")) continue;
        const ty = checker.typeOf(ni);
        const tystr = try checker.typeToString(ty);
        defer gpa.free(tystr);
        std.debug.print("p1: tag={s} ty='{s}'\n", .{@tagName(ast.nodeTag(ni)), tystr});
    }
}
