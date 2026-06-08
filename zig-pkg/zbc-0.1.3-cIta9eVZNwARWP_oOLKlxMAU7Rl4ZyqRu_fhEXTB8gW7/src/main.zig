//! zbc CLI — thin shell over the lib.zig library API.
//! Walks the .zig files passed on argv, runs escape analysis on each,
//! prints any Problems found in a grep-friendly format, and exits 0 if
//! all-clean / 1 if any problems.
//!
//! Usage:
//!   zbc [options] <file.zig>...
//!
//! Drop-in: run zbc on any Zig source; lifetime inference + the
//! pattern-detector rules fire without annotation requirements.
//!
//! Options:
//!   --enable=<list>      Comma-separated invariant names to enable.
//!   --disable=<list>     Comma-separated invariant names to disable.
//!   --arena-init=<csv>   Source-text patterns that mint a fresh
//!                        arena (default: ArenaAllocator.init).
//!   --arena-kill=<csv>   Source-text patterns that kill the receiver
//!                        arena (default: .deinit().
//!   --format=text|json   Output format (default: text).
//!   --list-invariants    Print known invariant names and exit 0.
//!   --list-rules         Print every rule id + title and exit 0.
//!   --explain <id>       Print the full explainer for one rule.
//!   -h / --help          Print usage and exit 0.

const std = @import("std");
const lib = @import("lib.zig");
const type_resolver_mod = @import("type_resolver.zig");

/// Silence ZLS's std.log info/debug output — zbc uses ZLS as a type
/// oracle, not as a language server, so its informational messages
/// ("Loaded build file ...", etc.) are pure noise on stderr that
/// pollutes grep-friendly sweeps.  Only ZLS warnings and errors
/// surface; zbc's own logs are unaffected (they use the default
/// scope).
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .analysis, .level = .warn },
        .{ .scope = .completions, .level = .warn },
        .{ .scope = .config, .level = .warn },
        .{ .scope = .diag, .level = .warn },
        .{ .scope = .goto, .level = .warn },
        .{ .scope = .inlay_hint, .level = .warn },
        .{ .scope = .main, .level = .warn },
        .{ .scope = .server, .level = .warn },
        .{ .scope = .store, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next(); // argv[0]

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(gpa);
    var enabled: std.ArrayListUnmanaged(lib.Invariant) = .empty;
    defer enabled.deinit(gpa);
    try enabled.appendSlice(gpa, &lib.all_invariants);
    var enabled_explicit = false;
    var format: Format = .rich;
    var color_off = false;

    var arena_init_patterns: []const []const u8 = lib.DefaultConfig.arena_init_patterns;
    var arena_kill_patterns: []const []const u8 = lib.DefaultConfig.arena_kill_patterns;
    var pattern_allocations: std.ArrayListUnmanaged([]const []const u8) = .empty;
    defer {
        for (pattern_allocations.items) |slice| gpa.free(slice);
        pattern_allocations.deinit(gpa);
    }

    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage();
            std.process.exit(0);
        }
        if (std.mem.eql(u8, a, "--list-invariants")) {
            inline for (@typeInfo(lib.Invariant).@"enum".fields) |f| {
                std.debug.print("{s}\n", .{f.name});
            }
            std.process.exit(0);
        }
        if (std.mem.eql(u8, a, "--list-rules")) {
            for (lib.rule_catalog) |r| {
                std.debug.print("{s} — {s}\n", .{ r.id, r.title });
            }
            std.process.exit(0);
        }
        if (std.mem.startsWith(u8, a, "--explain=")) {
            explainAndExit(a["--explain=".len..]);
        }
        if (std.mem.eql(u8, a, "--explain")) {
            const id = arg_it.next() orelse {
                std.debug.print("zbc: --explain requires a rule id (see --list-rules)\n", .{});
                std.process.exit(2);
            };
            explainAndExit(id);
        }
        if (std.mem.startsWith(u8, a, "--enable=")) {
            if (!enabled_explicit) {
                enabled.clearRetainingCapacity();
                enabled_explicit = true;
            }
            try parseInvariantList(gpa, a["--enable=".len..], &enabled, .add);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--disable=")) {
            try parseInvariantList(gpa, a["--disable=".len..], &enabled, .remove);
            continue;
        }
        if (std.mem.startsWith(u8, a, "--arena-init=")) {
            const slice = try splitCsv(gpa, a["--arena-init=".len..]);
            try pattern_allocations.append(gpa, slice);
            arena_init_patterns = slice;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--arena-kill=")) {
            const slice = try splitCsv(gpa, a["--arena-kill=".len..]);
            try pattern_allocations.append(gpa, slice);
            arena_kill_patterns = slice;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--format=")) {
            const v = a["--format=".len..];
            if (std.mem.eql(u8, v, "text") or std.mem.eql(u8, v, "rich")) {
                format = .rich;
            } else if (std.mem.eql(u8, v, "compact")) {
                format = .compact;
            } else if (std.mem.eql(u8, v, "json")) {
                format = .json;
            } else {
                std.debug.print("zbc: unknown format `{s}` (expected rich, compact, or json)\n", .{v});
                std.process.exit(2);
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--no-color")) {
            color_off = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--trace=")) {
            const v = a["--trace=".len..];
            if (std.mem.eql(u8, v, "*")) {
                lib.trace.all_rules = true;
            } else {
                lib.trace.active_rule = v;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            std.debug.print("zbc: unknown flag: {s}\n", .{a});
            printUsage();
            std.process.exit(2);
        }
        try paths.append(gpa, a);
    }

    if (paths.items.len == 0) {
        printUsage();
        std.process.exit(2);
    }

    var expanded: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (expanded.items) |p| gpa.free(p);
        expanded.deinit(gpa);
    }
    for (paths.items) |p| {
        expandPath(gpa, io, p, &expanded) catch |err| {
            std.debug.print("zbc: cannot expand {s}: {s}\n", .{ p, @errorName(err) });
            std.process.exit(2);
        };
    }
    if (expanded.items.len == 0) {
        std.debug.print("zbc: no .zig files found in: {s}\n", .{paths.items[0]});
        std.process.exit(0);
    }

    const config: lib.Config = .{
        .arena_init_patterns = arena_init_patterns,
        .arena_kill_patterns = arena_kill_patterns,
        .enabled = enabled.items,
    };

    const tasks = try gpa.alloc(Task, expanded.items.len);
    defer gpa.free(tasks);
    for (expanded.items, tasks) |path, *t| {
        t.* = .{
            .gpa = gpa,
            .io = io,
            .path = path,
            .config = &config,
            .problems = &.{},
            .err = null,
        };
    }

    // Work-stealing thread pool — N workers pop tasks off a shared
    // atomic counter.  `Io.Group.concurrent` grows its thread pool
    // lazily (only when ALL existing threads are busy), which on a
    // fast-per-file workload like ours saturates at ~2 threads
    // even on an 8-core machine.  Raw `std.Thread.spawn` lets us
    // pre-allocate one worker per CPU and consume the task list
    // in parallel.  Measured: 6:49 → ~1:00 on full Bun sweep.
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const worker_count = @max(1, @min(cpu_count, tasks.len));
    const workers = try gpa.alloc(std.Thread, worker_count);
    defer gpa.free(workers);
    var next_task: std.atomic.Value(usize) = .init(0);
    const ctx: WorkerCtx = .{ .tasks = tasks, .next = &next_task, .gpa = gpa, .io = io };
    // Pre-warm toolchain cache on the main thread so worker threads never
    // race to populate it concurrently (discoverToolchain is not thread-safe).
    type_resolver_mod.warmToolchain(gpa, io);
    var spawned: usize = 0;
    for (workers) |*w| {
        w.* = std.Thread.spawn(.{}, workerLoop, .{ctx}) catch
            // If a worker fails to spawn, fall back to serial in
            // the main thread for remaining tasks.
            break;
        spawned += 1;
    }
    // Main thread also helps drain the queue.
    workerLoop(ctx);
    for (workers[0..spawned]) |w| w.join();

    var all_problems: std.ArrayListUnmanaged(IndexedProblem) = .empty;
    defer all_problems.deinit(gpa);
    var any_problems = false;
    for (tasks) |*t| {
        if (t.err) |err| {
            std.debug.print("zbc: cannot analyze {s}: {s}\n", .{ t.path, @errorName(err) });
            any_problems = true;
            continue;
        }
        for (t.problems) |p| {
            try all_problems.append(gpa, .{ .path = t.path, .problem = p });
        }
    }
    defer for (tasks) |*t| if (t.problems.len > 0) gpa.free(t.problems);
    defer for (all_problems.items) |*ip| ip.problem.deinit(gpa);

    std.mem.sort(IndexedProblem, all_problems.items, {}, indexedProblemLess);

    if (all_problems.items.len > 0) any_problems = true;
    // `std.posix.system.isatty` is only exposed on platforms whose
    // system layer carries it (macOS/Darwin); Linux's posix.system
    // omits it.  Use the cross-platform `Io.File.isTty` instead.
    const use_color = !color_off and (std.Io.File.stderr().isTty(io) catch false);
    var src_cache: SourceCache = .{ .gpa = gpa, .io = io };
    defer src_cache.deinit();
    switch (format) {
        .json => {
            std.debug.print("[", .{});
            var first = true;
            for (all_problems.items) |ip| {
                printOneProblemJson(ip.path, ip.problem, &first);
            }
            std.debug.print("{s}]\n", .{if (first) "" else "\n"});
        },
        .compact => {
            for (all_problems.items) |ip| {
                printOneProblemCompact(ip.path, ip.problem);
            }
        },
        .rich => {
            for (all_problems.items) |ip| {
                printOneProblemRich(&src_cache, ip.path, ip.problem, use_color);
            }
        },
    }
    std.process.exit(if (any_problems) @as(u8, 1) else 0);
}

fn splitCsv(gpa: std.mem.Allocator, csv: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        try out.append(gpa, trimmed);
    }
    return out.toOwnedSlice(gpa);
}

fn expandPath(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        const duped = try gpa.dupe(u8, path);
        errdefer gpa.free(duped);
        try out.append(gpa, duped);
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.indexOf(u8, entry.path, "/.") != null) continue;
        if (std.mem.startsWith(u8, entry.path, ".")) continue;

        const full = try std.fs.path.join(gpa, &.{ path, entry.path });
        errdefer gpa.free(full);
        try out.append(gpa, full);
    }
}

const Format = enum { rich, compact, json };
const Op = enum { add, remove };

fn parseInvariantList(
    gpa: std.mem.Allocator,
    csv: []const u8,
    list: *std.ArrayListUnmanaged(lib.Invariant),
    op: Op,
) !void {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        const inv = lib.invariantFromName(name) orelse {
            std.debug.print("zbc: unknown invariant `{s}`; --list-invariants for valid names\n", .{name});
            std.process.exit(2);
        };
        switch (op) {
            .add => {
                if (!containsInvariant(list.items, inv)) try list.append(gpa, inv);
            },
            .remove => {
                var i: usize = 0;
                while (i < list.items.len) {
                    if (list.items[i] == inv) {
                        _ = list.orderedRemove(i);
                    } else i += 1;
                }
            },
        }
    }
}

fn containsInvariant(slice: []const lib.Invariant, inv: lib.Invariant) bool {
    for (slice) |e| if (e == inv) return true;
    return false;
}

fn explainAndExit(id: []const u8) noreturn {
    if (lib.lookupRule(id)) |r| {
        std.debug.print("{s}", .{r.body});
        std.process.exit(0);
    }
    std.debug.print("zbc: no rule named `{s}` (see --list-rules)\n", .{id});
    std.process.exit(2);
}

fn printUsage() void {
    std.debug.print(
        \\usage: zbc [options] <file.zig>...
        \\
        \\Escape analysis: flags slices borrowed from a function-local
        \\arena that are returned past the arena's death, plus a battery
        \\of pattern-detector rules for memory-lifetime bug classes.
        \\
        \\options:
        \\  --enable=a,b,c        Enable only these invariants.
        \\  --disable=a,b         Disable these invariants from the set.
        \\  --arena-init=A,B      Patterns that mint a fresh arena
        \\                        (default: ArenaAllocator.init).
        \\  --arena-kill=A,B      Patterns that kill the receiver arena
        \\                        (default: .deinit().
        \\  --format=rich|compact|json
        \\                        Output format.  Default `rich` shows
        \\                        gcc/clang-style header (path:line:col:
        \\                        error(rule-id): message) plus a
        \\                        Rust-style source-context block.
        \\                        `compact` is single-line grep-friendly.
        \\  --no-color            Disable ANSI color in `rich` output.
        \\  --list-invariants     Print known invariant names and exit.
        \\  --list-rules          Print every rule id and one-line title
        \\                        and exit.
        \\  --explain <id>        Print the full explainer for one rule
        \\                        (use --list-rules for valid ids).
        \\  -h, --help            Print this help.
        \\
    , .{});
}

const Task = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    config: *const lib.Config,
    problems: []lib.Problem,
    err: ?anyerror,
};

const IndexedProblem = struct {
    path: []const u8,
    problem: lib.Problem,
};

fn indexedProblemLess(_: void, a: IndexedProblem, b: IndexedProblem) bool {
    const path_cmp = std.mem.order(u8, a.path, b.path);
    if (path_cmp != .eq) return path_cmp == .lt;
    if (a.problem.start.line != b.problem.start.line)
        return a.problem.start.line < b.problem.start.line;
    return a.problem.start.column < b.problem.start.column;
}

const WorkerCtx = struct {
    tasks: []Task,
    next: *std.atomic.Value(usize),
    gpa: std.mem.Allocator,
    io: std.Io,
};

fn workerLoop(ctx: WorkerCtx) void {
    var type_ctx: type_resolver_mod.TypeContext = undefined;
    const ctx_ok = blk: {
        type_ctx.init(ctx.gpa, ctx.io) catch break :blk false;
        break :blk true;
    };
    defer if (ctx_ok) type_ctx.deinit();
    const type_ctx_ptr: ?*type_resolver_mod.TypeContext = if (ctx_ok) &type_ctx else null;

    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.tasks.len) return;
        runOne(&ctx.tasks[i], type_ctx_ptr) catch {};
    }
}

fn runOne(t: *Task, type_ctx: ?*type_resolver_mod.TypeContext) std.Io.Cancelable!void {
    const problems = lib.analyzeEscape(t.gpa, t.io, t.path, t.config, type_ctx) catch |err| {
        t.err = err;
        return;
    };
    t.problems = problems;
}

fn printOneProblemCompact(path: []const u8, p: lib.Problem) void {
    // gcc/clang-style header — path:line:col first, then
    // `severity(rule-id):`, then message.  Grep-friendly because the
    // file:line:col leads, and the rule_id is parenthesised inline.
    std.debug.print("{s}:{}:{}: {s}({s}): {s}", .{
        path,
        p.start.line,
        p.start.column,
        severityName(p.severity),
        p.rule_id,
        p.message,
    });
    // Tack each note's location and label onto the same line so the
    // single-line shape stays grep-friendly while still carrying the
    // related-event spans.
    for (p.notes) |n| {
        std.debug.print(" ({s} at {s}:{}:{})", .{
            n.label, path, n.start.line, n.start.column,
        });
    }
    std.debug.print("\n", .{});
}

// ── Rich renderer (gcc/clang header + Rust source-context block) ─────

const SourceCache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    entries: std.StringHashMapUnmanaged([]u8) = .empty,

    fn get(self: *SourceCache, path: []const u8) ?[]const u8 {
        if (self.entries.get(path)) |s| return s;
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.gpa,
            std.Io.Limit.limited(16 * 1024 * 1024),
        ) catch return null;
        const key = self.gpa.dupe(u8, path) catch {
            self.gpa.free(bytes);
            return null;
        };
        self.entries.put(self.gpa, key, bytes) catch {
            self.gpa.free(bytes);
            self.gpa.free(key);
            return null;
        };
        return bytes;
    }

    fn deinit(self: *SourceCache) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.entries.deinit(self.gpa);
    }
};

const Ansi = struct {
    reset: []const u8,
    bold: []const u8,
    red: []const u8,
    yellow: []const u8,
    blue: []const u8,
    cyan: []const u8,

    fn pick(use_color: bool) Ansi {
        return if (use_color) .{
            .reset = "\x1b[0m",
            .bold = "\x1b[1m",
            .red = "\x1b[31m",
            .yellow = "\x1b[33m",
            .blue = "\x1b[34m",
            .cyan = "\x1b[36m",
        } else .{
            .reset = "",
            .bold = "",
            .red = "",
            .yellow = "",
            .blue = "",
            .cyan = "",
        };
    }
};

fn printOneProblemRich(
    cache: *SourceCache,
    path: []const u8,
    p: lib.Problem,
    use_color: bool,
) void {
    const c = Ansi.pick(use_color);
    const sev_color = switch (p.severity) {
        .@"error" => c.red,
        .warning => c.yellow,
        .off => c.cyan,
    };

    // Header:  path:line:col: error(heap-use-after-free): use of `x` after free
    //
    // gcc/clang-style: file location leads, then `severity(rule-id):`,
    // then the message.  Editors / `grep -E` patterns / IDE jump-to-
    // diagnostic tooling all parse `path:line:col` at the start of
    // the line, so the rich format keeps the same shape as compact —
    // just with source context underneath.
    std.debug.print("{s}:{}:{}: ", .{ path, p.start.line, p.start.column });
    std.debug.print("{s}{s}{s}{s}", .{ c.bold, sev_color, severityName(p.severity), c.reset });
    std.debug.print("({s}{s}{s})", .{ c.cyan, p.rule_id, c.reset });
    std.debug.print(": {s}{s}{s}\n", .{ c.bold, p.message, c.reset });

    // Source-context block — no separate `--> path:line:col` line,
    // since the gcc/clang-style header already carries it.
    const src_opt = cache.get(path);
    const gutter_width = pickGutterWidth(p);

    if (src_opt) |src| {
        // Blank gutter row before the primary span.
        pad(gutter_width);
        std.debug.print(" {s}|{s}\n", .{ c.blue, c.reset });

        renderSpan(src, p.start, p.end, "", sev_color, '^', c, gutter_width);

        for (p.notes) |n| {
            // For notes in the SAME file, render with the same gutter
            // alignment so the eye can connect them.  External files
            // (none today, but cheap to support) would print their own
            // path lines.
            pad(gutter_width);
            std.debug.print(" {s}|{s}\n", .{ c.blue, c.reset });
            renderSpan(src, n.start, n.end, n.label, c.blue, '-', c, gutter_width);
        }
    } else {
        // Source unavailable — fall back to printing the note locations
        // textually so we don't drop the info.
        for (p.notes) |n| {
            pad(gutter_width);
            std.debug.print(" {s}={s} {s} at {s}:{}:{}\n", .{
                c.blue, c.reset, n.label, path, n.start.line, n.start.column,
            });
        }
    }

    // = help: footer — point at the catalog when the rule is in it.
    // Matches Rustc's `= help: for more information about this error,
    // try \`rustc --explain E0382\`.` line.  Only print when the rule
    // actually has an explainer; suppress otherwise so internal /
    // experimental rules don't promise docs that don't exist.
    if (lib.lookupRule(p.rule_id) != null) {
        pad(gutter_width);
        std.debug.print(" {s}={s} {s}help{s}: for more information, run `zbc --explain {s}`\n", .{
            c.blue, c.reset, c.bold, c.reset, p.rule_id,
        });
    }

    std.debug.print("\n", .{});
}

/// Number of digits in the widest line number we'll print for this
/// problem — primary span + notes.  Gutter width = max digits + 1
/// space, matching Rustc.
fn pickGutterWidth(p: lib.Problem) usize {
    var max_line: u32 = p.start.line;
    for (p.notes) |n| {
        if (n.start.line > max_line) max_line = n.start.line;
    }
    return countDigits(max_line);
}

fn countDigits(n: u32) usize {
    if (n == 0) return 1;
    var v = n;
    var d: usize = 0;
    while (v > 0) : (v /= 10) d += 1;
    return d;
}

fn pad(width: usize) void {
    var i: usize = 0;
    while (i < width) : (i += 1) std.debug.print(" ", .{});
}

fn renderSpan(
    src: []const u8,
    start: lib.Pos,
    end: lib.Pos,
    label: []const u8,
    label_color: []const u8,
    caret_char: u8,
    c: Ansi,
    gutter_width: usize,
) void {
    // Find the byte range of `start.line` in src.
    const line_text = sliceLine(src, start.byte);
    // Print the source line:  NNN | <text>
    const line_str_buf: [16]u8 = @splat(0);
    var buf = line_str_buf;
    const ln_str = std.fmt.bufPrint(&buf, "{}", .{start.line}) catch "?";
    const lead = if (gutter_width > ln_str.len) gutter_width - ln_str.len else 0;
    pad(lead);
    std.debug.print("{s}{s} |{s} {s}\n", .{ c.blue, ln_str, c.reset, line_text });
    // Underline row.  Columns are 1-indexed.
    pad(gutter_width);
    std.debug.print(" {s}|{s} ", .{ c.blue, c.reset });
    // Pad to start column.
    if (start.column > 1) {
        var i: u32 = 1;
        while (i < start.column) : (i += 1) std.debug.print(" ", .{});
    }
    // Caret length: end.column - start.column on same line; otherwise
    // 1 (multi-line spans are rare here).
    var caret_len: u32 = 1;
    if (end.line == start.line and end.column > start.column) {
        caret_len = end.column - start.column;
    }
    std.debug.print("{s}", .{label_color});
    var i: u32 = 0;
    while (i < caret_len) : (i += 1) std.debug.print("{c}", .{caret_char});
    if (label.len > 0) {
        std.debug.print(" {s}", .{label});
    }
    std.debug.print("{s}\n", .{c.reset});
}

/// Slice `src` to the line containing `byte_offset` (without the
/// newline).  If `byte_offset` is past EOF, returns an empty slice.
fn sliceLine(src: []const u8, byte_offset: u32) []const u8 {
    if (byte_offset >= src.len) return "";
    var ls: usize = byte_offset;
    while (ls > 0 and src[ls - 1] != '\n') ls -= 1;
    var le: usize = byte_offset;
    while (le < src.len and src[le] != '\n') le += 1;
    return src[ls..le];
}

fn printOneProblemJson(path: []const u8, p: lib.Problem, first: *bool) void {
    if (first.*) {
        std.debug.print("\n  ", .{});
        first.* = false;
    } else {
        std.debug.print(",\n  ", .{});
    }
    std.debug.print("{{\"path\":\"", .{});
    writeJsonEscaped(path);
    std.debug.print(
        "\",\"rule_id\":\"{s}\",\"severity\":\"{s}\"," ++
            "\"start\":{{\"line\":{},\"column\":{},\"byte\":{}}}," ++
            "\"end\":{{\"line\":{},\"column\":{},\"byte\":{}}}," ++
            "\"message\":\"",
        .{
            p.rule_id,
            severityName(p.severity),
            p.start.line, p.start.column, p.start.byte,
            p.end.line,   p.end.column,   p.end.byte,
        },
    );
    writeJsonEscaped(p.message);
    std.debug.print("\",\"notes\":[", .{});
    for (p.notes, 0..) |n, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print(
            "{{\"start\":{{\"line\":{},\"column\":{},\"byte\":{}}}," ++
                "\"end\":{{\"line\":{},\"column\":{},\"byte\":{}}}," ++
                "\"label\":\"",
            .{
                n.start.line, n.start.column, n.start.byte,
                n.end.line,   n.end.column,   n.end.byte,
            },
        );
        writeJsonEscaped(n.label);
        std.debug.print("\"}}", .{});
    }
    std.debug.print("]}}", .{});
}

fn severityName(s: lib.Severity) []const u8 {
    return switch (s) {
        .@"error" => "error",
        .warning => "warning",
        .off => "off",
    };
}

fn writeJsonEscaped(s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => std.debug.print("\\\"", .{}),
            '\\' => std.debug.print("\\\\", .{}),
            '\n' => std.debug.print("\\n", .{}),
            '\r' => std.debug.print("\\r", .{}),
            '\t' => std.debug.print("\\t", .{}),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => std.debug.print("\\u{x:0>4}", .{c}),
            else => std.debug.print("{c}", .{c}),
        }
    }
}

fn jsonEscapeToBuf(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(gpa, "\\\""),
            '\\' => try list.appendSlice(gpa, "\\\\"),
            '\n' => try list.appendSlice(gpa, "\\n"),
            '\r' => try list.appendSlice(gpa, "\\r"),
            '\t' => try list.appendSlice(gpa, "\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var buf: [6]u8 = undefined;
                const hex = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                try list.appendSlice(gpa, hex);
            },
            else => try list.append(gpa, c),
        }
    }
    return list.toOwnedSlice(gpa);
}

// ── Tests ──────────────────────────────────────────────────

test "parseInvariantList: add single" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(lib.Invariant) = .empty;
    defer list.deinit(gpa);
    try parseInvariantList(gpa, "arena_escape", &list, .add);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(lib.Invariant.arena_escape, list.items[0]);
}

test "parseInvariantList: add dedupes" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(lib.Invariant) = .empty;
    defer list.deinit(gpa);
    try parseInvariantList(gpa, "arena_escape,arena_escape", &list, .add);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
}

test "parseInvariantList: remove from a set" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(lib.Invariant) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, &lib.all_invariants);
    try parseInvariantList(gpa, "arena_escape", &list, .remove);
    try std.testing.expect(!containsInvariant(list.items, .arena_escape));
}

test "splitCsv: basic comma-separated" {
    const gpa = std.testing.allocator;
    const out = try splitCsv(gpa, "a,b,c");
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("a", out[0]);
    try std.testing.expectEqualStrings("c", out[2]);
}

test "splitCsv: trims whitespace, drops empties" {
    const gpa = std.testing.allocator;
    const out = try splitCsv(gpa, "  Foo.parse , , Bar.make ,");
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("Foo.parse", out[0]);
    try std.testing.expectEqualStrings("Bar.make", out[1]);
}

test "jsonEscapeToBuf: passes ASCII through unchanged" {
    const gpa = std.testing.allocator;
    const s = try jsonEscapeToBuf(gpa, "hello, world (idx=42)");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("hello, world (idx=42)", s);
}

test "jsonEscapeToBuf: escapes quote, backslash, common control chars" {
    const gpa = std.testing.allocator;
    const s = try jsonEscapeToBuf(gpa, "a\"b\\c\nd\te");
    defer gpa.free(s);
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd\\te", s);
}

test "jsonEscapeToBuf: low control bytes become \\uXXXX" {
    const gpa = std.testing.allocator;
    const s = try jsonEscapeToBuf(gpa, &[_]u8{ 'x', 0x01, 'y', 0x1f, 'z' });
    defer gpa.free(s);
    try std.testing.expectEqualStrings("x\\u0001y\\u001fz", s);
}

test {
    _ = lib;
    std.testing.refAllDecls(@This());
}
