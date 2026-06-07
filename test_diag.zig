const std = @import("std");
const parser = @import("es_parser");
const Ast = parser.ast.Ast;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const source = @embedFile("/tmp/test_enum.ts");
    
    var parse_result = try parser.parse(allocator, source, "/tmp/test_enum.ts");
    defer parse_result.deinit();
    
    const sem = try parser.semantic.SemanticAnalyzer.analyze(allocator, &parse_result.ast);
    defer sem.deinit(allocator);
    
    std.debug.print("Diagnostics: {}\n", .{sem.diagnostics.len});
    for (sem.diagnostics, 0..) |diag, i| {
        std.debug.print("  {}: severity={}, message={s}, span=[{}, {})\n", .{i, diag.severity, diag.message, diag.span.start, diag.span.end});
    }
}
