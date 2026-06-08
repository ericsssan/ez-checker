//! Type resolution engine for zbc — repo-wide deep static analysis.
//!
//! Wraps the extracted type-resolution machinery (DocumentStore +
//! InternPool + Analyser) behind a zbc-shaped API.
//!
//! TypeContext  — long-lived per-thread state.  Holds DocumentStore +
//!                InternPool so stdlib files are parsed and typed once
//!                per thread.  In-place init required (self-referential
//!                pointers).  Never move after init.
//!
//! TypeResolver — per-file state.  Borrows a TypeContext; owns only
//!                the per-file arena and Analyser.

const std = @import("std");
const Ast = std.zig.Ast;

const DocumentStore = @import("document_store.zig");
const InternPool = @import("intern_pool.zig");
const Analyser = @import("analysis.zig");
const Uri = @import("uri.zig");
const DiagnosticsCollection = @import("diagnostics_collection.zig");

// ── Toolchain discovery ───────────────────────────────────────────────

const ToolchainPaths = struct {
    zig_exe: ?[]const u8 = null,
    zig_lib: ?[]const u8 = null,
    build_runner: ?[]const u8 = null,
    initialized: bool = false,
};

var global_toolchain: ToolchainPaths = .{};

/// Process-global toolchain cache.  NOT thread-safe — must be called
/// exactly once from the main thread (via type_resolver.warmToolchain)
/// before any worker threads start, so workers read an already-populated
/// cache rather than racing to write it.
pub fn discoverToolchain(io: std.Io) ToolchainPaths {
    if (global_toolchain.initialized) return global_toolchain;
    const cache_gpa = std.heap.c_allocator;
    global_toolchain.zig_exe = findZigExe(cache_gpa, io, cache_gpa) catch null;
    global_toolchain.zig_lib = if (global_toolchain.zig_exe) |z|
        findZigLibDir(cache_gpa, io, cache_gpa, z) catch null
    else
        null;
    global_toolchain.build_runner = if (global_toolchain.zig_lib != null)
        findBuildRunner(cache_gpa, io) catch null
    else
        null;
    global_toolchain.initialized = true;
    return global_toolchain;
}

pub fn clearToolchainCacheForTesting() void {
    const cache_gpa = std.heap.c_allocator;
    if (global_toolchain.zig_exe) |p| cache_gpa.free(p);
    if (global_toolchain.zig_lib) |p| cache_gpa.free(p);
    if (global_toolchain.build_runner) |p| cache_gpa.free(p);
    global_toolchain = .{};
}

fn findZigExe(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    const raw = try runCapture(gpa, io, &.{ "/usr/bin/which", "zig" });
    defer gpa.free(raw);
    return try arena.dupe(u8, std.mem.trimEnd(u8, raw, &std.ascii.whitespace));
}

fn findZigLibDir(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, zig_exe: []const u8) ![]const u8 {
    const env_out = try runCapture(gpa, io, &.{ zig_exe, "env" });
    defer gpa.free(env_out);
    // `zig env` output format: older Zig emitted JSON (`"lib_dir":"…"`);
    // Zig 0.17-dev switched to ZON (`.lib_dir = "…"`).  Locate the `lib_dir`
    // key, then take the value as the text between the next two double quotes —
    // robust to both formats and to spacing.
    const key = std.mem.indexOf(u8, env_out, "lib_dir") orelse return error.NotFound;
    const q1 = std.mem.indexOfScalarPos(u8, env_out, key + "lib_dir".len, '"') orelse return error.NotFound;
    const q2 = std.mem.indexOfScalarPos(u8, env_out, q1 + 1, '"') orelse return error.NotFound;
    if (q2 <= q1 + 1) return error.NotFound;
    return try arena.dupe(u8, env_out[q1 + 1 .. q2]);
}

fn runCapture(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return error.NotFound;
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            gpa.free(result.stdout);
            return error.NotFound;
        },
        else => {
            gpa.free(result.stdout);
            return error.NotFound;
        },
    }
    if (result.stdout.len == 0) {
        gpa.free(result.stdout);
        return error.NotFound;
    }
    return result.stdout;
}

fn findBuildRunner(_: std.mem.Allocator, _: std.Io) ![]const u8 {
    // Build-configuration loading is disabled (global_cache_dir = null),
    // so the build runner path is never used by DocumentStore.
    return error.NotFound;
}

// ── TypeContext ───────────────────────────────────────────────────────

/// Long-lived per-thread type-resolution state.  The DocumentStore
/// and InternPool persist across files processed by the same thread,
/// so stdlib is parsed and its types interned once per thread.
///
/// In-place init required: self-referential pointers
/// (store.config.environ_map → &self.environ_map,
///  store.diagnostics_collection → &self.diagnostics).
/// Never move after init.
pub const TypeContext = struct {
    gpa: std.mem.Allocator,
    ip: InternPool,
    diagnostics: DiagnosticsCollection,
    environ_map: std.process.Environ.Map,
    store: DocumentStore,

    pub fn init(self: *TypeContext, gpa: std.mem.Allocator, io: std.Io) !void {
        self.gpa = gpa;

        self.ip = try InternPool.init(io, gpa);
        errdefer self.ip.deinit(gpa);

        self.diagnostics = .{ .io = io, .allocator = gpa };
        self.environ_map = .init(gpa);

        const tc = discoverToolchain(io);
        const zig_lib: ?std.Build.Cache.Directory = if (tc.zig_lib) |p|
            .{ .path = p, .handle = .cwd() }
        else
            null;

        self.store = .{
            .io = io,
            .allocator = gpa,
            .config = .{
                .environ_map = &self.environ_map,
                .zig_exe_path = tc.zig_exe,
                .zig_lib_dir = zig_lib,
                .build_runner_path = tc.build_runner,
                .builtin_path = null,
                .global_cache_dir = null,
                .wasi_preopens = {},
            },
            .diagnostics_collection = &self.diagnostics,
        };
    }

    pub fn deinit(self: *TypeContext) void {
        self.store.deinit();
        self.diagnostics.deinit();
        self.ip.deinit(self.gpa);
    }
};

// ── TypeResolver ─────────────────────────────────────────────────────

/// Per-file type resolver.  Borrows a TypeContext (DocumentStore +
/// InternPool).  Per-file documents stay open for the thread's lifetime
/// so InternPool entries referencing them remain valid.
pub const TypeResolver = struct {
    gpa: std.mem.Allocator,
    ctx: *TypeContext,
    arena: std.heap.ArenaAllocator,
    handle: *DocumentStore.Handle,
    analyser: Analyser,

    pub fn init(
        self: *TypeResolver,
        ctx: *TypeContext,
        gpa: std.mem.Allocator,
        file_path: []const u8,
        source: [:0]const u8,
    ) !void {
        self.gpa = gpa;
        self.ctx = ctx;
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();

        const handle_uri: Uri = try .fromPath(self.arena.allocator(), file_path);
        try ctx.store.openLspSyncedDocument(handle_uri, source);
        self.handle = ctx.store.getHandle(handle_uri) orelse return error.HandleMissing;

        self.analyser = Analyser.init(
            gpa,
            self.arena.allocator(),
            &ctx.store,
            &ctx.ip,
            self.handle,
        );
    }

    pub fn deinit(self: *TypeResolver) void {
        self.analyser.deinit();
        self.arena.deinit();
    }

    pub fn typeNameOfNode(self: *TypeResolver, node: Ast.Node.Index) !?[]const u8 {
        const ty_maybe = try self.analyser.resolveTypeOfNode(.of(node, self.handle));
        const ty = ty_maybe orelse return null;

        var cur = ty;
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            switch (cur.data) {
                .pointer => |p| cur = p.elem_ty.*,
                .optional => |inner| cur = inner.*,
                .array => |a| cur = a.elem_ty.*,
                else => break,
            }
        }

        return switch (cur.data) {
            .container => |container| try containerName(self.arena.allocator(), container),
            else => null,
        };
    }

    pub fn resolvedTypeIsPointer(self: *TypeResolver, node: Ast.Node.Index) !bool {
        const ty_maybe = try self.analyser.resolveTypeOfNode(.of(node, self.handle));
        const ty = ty_maybe orelse return false;
        return ty.data == .pointer;
    }

    pub fn isOptionalType(self: *TypeResolver, node: Ast.Node.Index) !bool {
        const ty_maybe = try self.analyser.resolveTypeOfNode(.of(node, self.handle));
        const ty = ty_maybe orelse return false;
        return switch (ty.data) {
            .optional => true,
            .ip_index => |payload| switch (self.ctx.ip.indexToKey(payload.type)) {
                .optional_type => true,
                else => false,
            },
            else => false,
        };
    }

    pub fn isRawSinglePointerType(self: *TypeResolver, node: Ast.Node.Index) !bool {
        const ty_maybe = try self.analyser.resolveTypeOfNode(.of(node, self.handle));
        const ty = ty_maybe orelse return false;
        return switch (ty.data) {
            .pointer => |info| info.size == .one,
            .ip_index => |payload| switch (self.ctx.ip.indexToKey(payload.type)) {
                .pointer_type => |info| info.flags.size == .one,
                else => false,
            },
            else => false,
        };
    }

    /// For a TYPE-NAME reference node `T` (e.g. the inner `T` of a `?*?T`
    /// annotation): does `T` denote a pointer or optional type?  Resolves the
    /// reference to its denoted type (a type-value) and inspects its structure.
    ///   true  → `T` is a pointer/optional (so `?*?T` is a valid nullable-ptr-
    ///           to-optional-ptr, not the duplicated-`?`-on-a-value bug)
    ///   false → `T` denotes a non-pointer value type
    ///   null  → couldn't resolve
    pub fn typeRefIsPointerLike(self: *TypeResolver, node: Ast.Node.Index) !?bool {
        const ty = (try self.analyser.resolveTypeOfNode(.of(node, self.handle))) orelse return null;
        switch (ty.data) {
            .pointer, .optional => return true,
            .ip_index => |payload| {
                // For a type-VALUE (`is_type_val`), the denoted type is in
                // `index` (the value); `type` is the meta-type `type`.
                const denoted = if (ty.is_type_val) (payload.index orelse return null) else payload.type;
                return switch (self.ctx.ip.indexToKey(denoted)) {
                    .pointer_type, .optional_type => true,
                    else => false,
                };
            },
            else => return null,
        }
    }

    pub const IntInfo = struct { signed: bool, bits: u16 };

    /// Signedness and bit-width of `node`'s type when it resolves to an integer
    /// type, else null.  Used e.g. to tell signed subtraction (well-defined,
    /// can't "wrap to a huge value") from unsigned underflow.
    pub fn intInfo(self: *TypeResolver, node: Ast.Node.Index) !?IntInfo {
        const ty = (try self.analyser.resolveTypeOfNode(.of(node, self.handle))) orelse return null;
        return switch (ty.data) {
            .ip_index => |payload| switch (self.ctx.ip.indexToKey(payload.type)) {
                .int_type => |i| .{ .signed = i.signedness == .signed, .bits = i.bits },
                else => null,
            },
            else => null,
        };
    }

    /// For `x.ptr` where `x`'s type resolves to a slice / many-pointer:
    /// returns whether the element type is byte-sized (1-byte alignment —
    /// `u8`/`i8`/`bool`/≤8-bit ints), i.e. `x` is a genuine byte slice whose
    /// `.ptr` is only 1-aligned (the `@alignCast`-on-byte-slice bug class).
    ///   true  → byte slice (align 1) — the cast may misalign.
    ///   false → element is wider (u16+/pointer) → `.ptr` already >1-aligned,
    ///           NOT a byte slice; this rule does not apply.
    ///   null  → unresolved, not a slice, or element of unknown alignment
    ///           (struct/array) — caller should fall back to syntax.
    pub fn sourcePtrElemByteSized(self: *TypeResolver, node: Ast.Node.Index) !?bool {
        const ty = (try self.analyser.resolveTypeOfNode(.of(node, self.handle))) orelse return null;
        switch (ty.data) {
            .pointer => |p| {
                if (p.size == .one) return null;
                return self.typeIsByteSized(p.elem_ty.*);
            },
            .ip_index => |payload| switch (self.ctx.ip.indexToKey(payload.type)) {
                .pointer_type => |info| {
                    if (info.flags.size == .one) return null;
                    return self.ipIsByteSized(info.elem_type);
                },
                else => return null,
            },
            else => return null,
        }
    }

    fn typeIsByteSized(self: *TypeResolver, ty: Analyser.Type) ?bool {
        return switch (ty.data) {
            .ip_index => |payload| self.ipIsByteSized(payload.type),
            .pointer => false, // element is itself a pointer → ≥ pointer-aligned
            else => null, // struct/container/array → unknown alignment
        };
    }

    fn ipIsByteSized(self: *TypeResolver, idx: InternPool.Index) ?bool {
        return switch (self.ctx.ip.indexToKey(idx)) {
            .int_type => |i| i.bits <= 8,
            .simple_type => |s| switch (s) {
                .bool => true,
                else => null,
            },
            .pointer_type => false,
            else => null,
        };
    }

    /// Returns the compile-time element count of `node`'s type when it is a
    /// fixed-size array `[N]T`, a single-pointer to a fixed array `*[N]T` /
    /// `*const [N]T`, or an IP-backed array type.  Returns null for runtime
    /// slices (`[]T`), many-pointers, or any type whose length is not a
    /// compile-time constant.
    ///
    /// Sound for bounds reasoning: a non-null result is an exact, compiler-
    /// guaranteed length, so `arr[offset..]` is in-bounds iff offset <= N.
    pub fn fixedArrayLen(self: *TypeResolver, node: Ast.Node.Index) !?u64 {
        const ty_maybe = try self.analyser.resolveTypeOfNode(.of(node, self.handle));
        const ty = ty_maybe orelse return null;
        return self.fixedArrayLenOfType(ty, 0);
    }

    fn fixedArrayLenOfType(self: *TypeResolver, ty: Analyser.Type, depth: u8) ?u64 {
        if (depth > 4) return null;
        return switch (ty.data) {
            .array => |a| a.elem_count,
            // `*[N]T` / `*const [N]T` — a single pointer to a fixed array.
            // Slicing the pointer (`p[off..]`) is bounds-checked against N.
            .pointer => |p| if (p.size == .one)
                self.fixedArrayLenOfType(p.elem_ty.*, depth + 1)
            else
                null,
            .ip_index => |payload| switch (self.ctx.ip.indexToKey(payload.type)) {
                .array_type => |info| info.len,
                .pointer_type => |info| if (info.flags.size == .one)
                    switch (self.ctx.ip.indexToKey(info.elem_type)) {
                        .array_type => |arr| arr.len,
                        else => null,
                    }
                else
                    null,
                else => null,
            },
            else => null,
        };
    }
};

fn containerName(arena: std.mem.Allocator, container: anytype) !?[]const u8 {
    const handle = container.scope_handle.handle;
    const scope_node = container.scope_handle.toNode();
    const tree = handle.tree;
    const tags = tree.tokens.items(.tag);
    const first_token = tree.firstToken(scope_node);
    const max_scan = 32;
    var i: usize = 0;
    var t = first_token;
    while (i < max_scan and t > 0) : ({
        i += 1;
        t -= 1;
    }) {
        if (tags[t] == .identifier and t > 0) {
            const prev = tags[t - 1];
            if (prev == .keyword_const or prev == .keyword_fn or
                prev == .keyword_var or prev == .keyword_pub)
            {
                return try arena.dupe(u8, tree.tokenSlice(t));
            }
        }
    }
    // File-root container: the file itself IS the struct (no enclosing
    // `const NAME = struct {…}`), as in std's `ArenaAllocator.zig`,
    // `array_list.zig`, etc.  Its name is the file's stem — the convention
    // ZLS uses.  e.g. `…/heap/ArenaAllocator.zig` → "ArenaAllocator".
    const fs_path = handle.uri.toFsPath(arena) catch return null;
    const stem = std.fs.path.stem(fs_path);
    if (stem.len == 0) return null;
    return try arena.dupe(u8, stem);
}
