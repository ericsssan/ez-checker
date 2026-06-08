//! Fuzz harness for the full lex → parse → semantic → type-check pipeline.
//!
//! Three entry points, all backed by the same `checkBytes` core:
//!
//!   1. `test "fuzz smoke"` — runs each seed once under `zig build test`.
//!      No server, no instrumentation, just crash-free confirmation.
//!
//!   2. `pub fn main()` — reads stdin and analyses it.  Used with AFL++:
//!        afl-fuzz -i corpus/ -o findings/ -- ./fuzz-ez
//!      Build:  zig build fuzz
//!
//!   3. `LLVMFuzzerTestOneInput` export — libfuzzer entry point.
//!      Build:  zig build fuzz-libfuzzer
//!      Run:    ./fuzz-ez-libfuzzer corpus/

const std = @import("std");
const parser = @import("es_parser");
const Checker = @import("checker.zig").Checker;

// ── Seeds ──────────────────────────────────────────────────────────────
// Representative JS/TS snippets covering major type inference paths.
pub const seeds: []const []const u8 = &.{
    // Literals
    "42;",
    "'hello';",
    "true; false;",
    "null; undefined;",
    // Declarations
    "const x: number = 1; x;",
    "let s: string = 'hi'; s;",
    "var b: boolean = true; b;",
    // Functions
    "function f(x: number): number { return x + 1; }",
    "const arrow = (a: string, b: string) => a + b;",
    "function opt(x?: number) { return x; }",
    "function rest(...args: string[]) { return args; }",
    // Objects and classes
    "const obj = { a: 1, b: 'x' }; obj.a;",
    "class Foo { x: number = 0; get val() { return this.x; } }",
    "class Bar extends Foo { y: string = ''; }",
    // Generics
    "function id<T>(x: T): T { return x; }",
    "type Box<T> = { value: T };",
    // Unions and intersections
    "type U = string | number; const x: U = 1;",
    "type I = { a: number } & { b: string };",
    // Enums
    "enum Dir { Up = 0, Down = 1 } Dir.Up;",
    "const enum Color { Red, Green, Blue }",
    // Control flow
    "function f(x: string | number) { if (typeof x === 'string') { x; } }",
    "function g(x: number | null) { if (x !== null) { x; } }",
    // Pathological / error-recovery inputs
    "",
    "   \n\t  ",
    "this is not typescript at all !!!",
    "function f() { { { { { { {} } } } } } }",
    "const x = ;",
    "class {}",
    "=> =>",
    "<></>",
};

// ── Core ───────────────────────────────────────────────────────────────
/// Run the full pipeline on `src` bytes.  Returns without reporting
/// findings — the caller only cares whether the pipeline crashes or leaks.
pub fn checkBytes(gpa: std.mem.Allocator, src: []const u8) !void {
    var lex_result = try parser.Lexer.tokenize(gpa, src);
    defer lex_result.deinit(gpa);
    var tokens = lex_result.tokens;

    var ast_result = try parser.Parser.parseWithLanguage(gpa, src, tokens.slice(), .ts, true);
    defer ast_result.deinit(gpa);

    var sem = try parser.semantic.SemanticAnalyzer.analyzeWithOptions(gpa, &ast_result, .{
        .is_module = true,
        .build_parents = true,
    });
    defer sem.deinit(gpa);

    var checker = try Checker.init(gpa, &ast_result, &sem);
    defer checker.deinit();

    // Drive type inference over every node so all code paths are exercised.
    var i: u32 = 1;
    while (i < ast_result.nodes.len) : (i += 1) {
        _ = checker.typeOf(@enumFromInt(i));
    }
}

// ── Entry point 1: smoke test ──────────────────────────────────────────
test "fuzz smoke: seeds do not crash the type-check pipeline" {
    const gpa = std.testing.allocator;
    for (seeds) |seed| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        checkBytes(arena.allocator(), seed) catch |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        };
    }
}

// ── Entry point 2: stdin reader (AFL++ / honggfuzz / manual) ───────────
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [65536]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &buf);
    const raw = stdin_reader.interface.allocRemaining(gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory, error.StreamTooLong => return,
        else => return err,
    };
    defer gpa.free(raw);

    checkBytes(gpa, raw) catch |err| switch (err) {
        error.OutOfMemory => return,
        else => return err,
    };
}

// ── Entry point 3: libfuzzer ───────────────────────────────────────────
export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.c) i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    checkBytes(arena.allocator(), data[0..size]) catch {};
    return 0;
}
