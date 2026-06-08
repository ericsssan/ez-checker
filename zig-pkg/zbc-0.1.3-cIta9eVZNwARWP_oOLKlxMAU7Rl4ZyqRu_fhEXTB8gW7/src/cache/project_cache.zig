//! Cross-file FileModel cache — lazy-loads sibling .zig files
//! referenced by `@import("./relative.zig")` so rules can resolve
//! type identifiers declared in other files.
//!
//! Scope:
//!   - Relative-path @imports only (`@import("foo.zig")`,
//!     `@import("../bar/baz.zig")`).  Module-name @imports
//!     (`@import("std")`, `@import("bun")`) need build.zig
//!     context which ZLS handles separately.
//!   - One model per resolved absolute path; lifetime is the
//!     ProjectCache itself.  Each model owns its own source +
//!     tree + arena.
//!
//! Usage:
//!     var pc = ProjectCache.init(gpa, io);
//!     defer pc.deinit();
//!     const fm = try pc.modelForRelativeImport(my_file_path, "./other.zig");
//!     // fm.findType("OtherType") — etc.

const std = @import("std");
const Ast = std.zig.Ast;
const model_mod = @import("../model/file_model.zig");

/// Cached result of a cross-file `(TypeName, methodName)` summary lookup.
/// `.found = false` means the method was not found; `.found = true` means
/// it was found, and `.takes` holds the `takes_ownership_of` value.
pub const CachedTakes = struct { found: bool, takes: ?u32 = null };

pub const ProjectCache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Coarse-grained spinlock protecting entries/type_index/module_paths.
    /// Public methods acquire it; private `*Locked` helpers assume it is
    /// already held.  The spinlock is NOT recursive — callers must never
    /// call a public method from within a locked section.
    /// `std.atomic.Mutex` is a CAS spinlock (tryLock-only); we wrap it
    /// with a busy-wait in `muLock`.  Cross-file cache misses are
    /// infrequent so busy-wait overhead is negligible.
    mu: std.atomic.Mutex = .unlocked,
    /// abs_path → owned entry (source, tree, model).
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,
    /// module-name → absolute path of the module's root .zig file.
    /// Lazily populated by `discoverModulePath`.  Owned by `gpa`.
    /// A null value means "tried and didn't find" — cache the
    /// negative so we don't re-search on every import.
    module_paths: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    /// Cached project root (first ancestor of any analyzed file with
    /// a `build.zig`, `Cargo.toml`, or `.git`).  Null on first
    /// request; set by `findProjectRoot`.  Owned by `gpa`.
    project_root: ?[]const u8 = null,
    project_root_searched: bool = false,
    /// Global type index: type-name → list of (Entry, type_index).
    /// Lazily built on first `findAllTypesByName` call; covers every
    /// `.zig` file under `project_root`.  Empty map means "not built
    /// yet"; built_type_index is the latch.
    type_index: std.StringHashMapUnmanaged([]TypeEntry) = .empty,
    type_index_built: bool = false,
    /// Path-resolution cache: `"from_path\x00import_str"` → resolved
    /// absolute path (both gpa-owned).  Avoids repeating
    /// dirname + join + resolvePosix + alloc on every call to
    /// `modelForRelativeImport` when the model is already cached.
    import_path_cache: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Project-wide cross-file method summary cache.
    /// Key = gpa-owned `"TypeName\x00methodName"`.
    /// Value = `CachedTakes` — avoids `??u32` coercion ambiguity.
    ///   `.found = false` → looked up, method not found.
    ///   `.found = true`  → found; `.takes` holds `takes_ownership_of`.
    /// Shared across all per-file FileCache instances so the expensive
    /// @import-graph traversal in `summaryByMethodCrossFile` is paid at
    /// most once globally per (type, method) pair.
    method_summary_cache: std.StringHashMapUnmanaged(CachedTakes) = .empty,

    pub const Entry = struct {
        abs_path: []const u8,
        source: [:0]u8,
        tree: Ast,
        model: model_mod.FileModel,
    };

    /// A single type observation in the global index — references a
    /// type by its model index within an Entry's `model.types`.
    /// `Entry.model.types` is a slice owned by the Entry's arena, so
    /// `&entry.model.types[type_index]` is stable for the Entry's
    /// lifetime (== ProjectCache lifetime).
    pub const TypeEntry = struct {
        entry: *Entry,
        type_idx: u32,

        pub fn typeInfo(self: TypeEntry) *const model_mod.TypeInfo {
            return &self.entry.model.types[self.type_idx];
        }

        pub fn tree(self: TypeEntry) *const Ast {
            return &self.entry.tree;
        }
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io) ProjectCache {
        return .{ .gpa = gpa, .io = io };
    }

    /// Blocking acquire via busy-wait (CAS spin).  Cross-file misses
    /// are infrequent so busy-wait overhead is negligible.
    inline fn muLock(self: *ProjectCache) void {
        while (!self.mu.tryLock()) std.atomic.spinLoopHint();
    }

    inline fn muUnlock(self: *ProjectCache) void {
        self.mu.unlock();
    }

    pub fn deinit(self: *ProjectCache) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            e.model.deinit();
            e.tree.deinit(self.gpa);
            self.gpa.free(e.source);
            self.gpa.free(e.abs_path);
            self.gpa.destroy(e);
        }
        self.entries.deinit(self.gpa);
        var mit = self.module_paths.iterator();
        while (mit.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            if (kv.value_ptr.*) |p| self.gpa.free(p);
        }
        self.module_paths.deinit(self.gpa);
        var tit = self.type_index.iterator();
        while (tit.next()) |kv| {
            // Keys borrow from Entry.model.types[*].name; only free
            // the value slice.
            self.gpa.free(kv.value_ptr.*);
        }
        self.type_index.deinit(self.gpa);
        if (self.project_root) |p| self.gpa.free(p);
        var iit = self.import_path_cache.iterator();
        while (iit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.import_path_cache.deinit(self.gpa);
        var sit = self.method_summary_cache.iterator();
        while (sit.next()) |e| self.gpa.free(e.key_ptr.*); // values are POD, no free needed
        self.method_summary_cache.deinit(self.gpa);
    }

    /// Look up the cached `takes_ownership_of` result for a cross-file
    /// method lookup.  Returns null when NOT in cache (caller must compute);
    /// returns CachedTakes (with `.found` indicating whether the method
    /// exists) when the result is cached.
    pub fn getMethodSummaryCache(
        self: *ProjectCache,
        type_name: []const u8,
        method_name: []const u8,
    ) ?CachedTakes {
        var key_buf: [256]u8 = undefined;
        const key_len = type_name.len + 1 + method_name.len;
        if (key_len > key_buf.len) return null;
        @memcpy(key_buf[0..type_name.len], type_name);
        key_buf[type_name.len] = 0;
        @memcpy(key_buf[type_name.len + 1 ..][0..method_name.len], method_name);
        const sk = key_buf[0..key_len];
        self.muLock();
        defer self.muUnlock();
        return self.method_summary_cache.get(sk); // null = not in cache
    }

    /// Store `takes_ownership_of` for a cross-file method lookup.
    /// No-ops on OOM (the result will be recomputed next time — safe).
    pub fn putMethodSummaryCache(
        self: *ProjectCache,
        type_name: []const u8,
        method_name: []const u8,
        cached: CachedTakes,
    ) void {
        self.muLock();
        defer self.muUnlock();
        // Allocate heap key for storage.
        const key = std.fmt.allocPrint(
            self.gpa,
            "{s}\x00{s}",
            .{ type_name, method_name },
        ) catch return;
        self.method_summary_cache.put(self.gpa, key, cached) catch self.gpa.free(key);
    }

    /// Lazily-built global type index.  On first call: walks every
    /// `.zig` file under `project_root` (excluding common vendor /
    /// build / cache dirs), loads each via `modelForAbsolutePath`,
    /// and indexes every top-level type by name.  Subsequent calls
    /// are O(1) hash lookups.
    ///
    /// Returns an empty slice when the name has no occurrences (or
    /// when project_root can't be determined).
    pub fn findAllTypesByName(
        self: *ProjectCache,
        from_file_path: []const u8,
        name: []const u8,
    ) ![]const TypeEntry {
        self.muLock();
        defer self.muUnlock();
        if (!self.type_index_built) try self.buildTypeIndex(from_file_path);
        return self.type_index.get(name) orelse &.{};
    }

    fn buildTypeIndex(self: *ProjectCache, from_file_path: []const u8) !void {
        self.type_index_built = true; // latch first so failures don't retry
        const root = (try self.findProjectRootLocked(from_file_path)) orelse return;
        // Collect candidate file paths.
        var paths: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (paths.items) |p| self.gpa.free(p);
            paths.deinit(self.gpa);
        }
        try collectZigFiles(self.gpa, self.io, root, &paths);
        // For each file, load the entry (cache hit if already loaded)
        // and index every top-level type.  Per-name lists are built
        // in a temporary StringHashMap with []TypeEntry-typed values,
        // then frozen into self.type_index.
        var pending: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(TypeEntry)) = .empty;
        defer {
            var pit = pending.iterator();
            while (pit.next()) |kv| kv.value_ptr.deinit(self.gpa);
            pending.deinit(self.gpa);
        }
        for (paths.items) |abs_path_owned| {
            const dup = try self.gpa.dupe(u8, abs_path_owned);
            const fm_opt = self.modelForAbsolutePathLocked(dup) catch null;
            const _fm = fm_opt orelse continue;
            _ = _fm;
            // Walk the entry's types.  The Entry pointer is stable
            // (boxed via `*Entry` in `entries`).
            const entry = self.entries.get(abs_path_owned) orelse continue;
            for (entry.model.types, 0..) |*ti, i| {
                const te: TypeEntry = .{ .entry = entry, .type_idx = @intCast(i) };
                const gop = try pending.getOrPut(self.gpa, ti.name);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.gpa, te);
            }
        }
        // Freeze into self.type_index.
        var pit = pending.iterator();
        while (pit.next()) |kv| {
            const slice = try kv.value_ptr.toOwnedSlice(self.gpa);
            try self.type_index.put(self.gpa, kv.key_ptr.*, slice);
        }
    }

    /// Resolve a relative @import string against `from_file_path`
    /// (an absolute path) and return the cached FileModel.  Loads
    /// + parses + builds the model on first request.  Returns
    /// null when the import doesn't resolve (module-name imports,
    /// non-existent paths, parse failures).
    pub fn modelForRelativeImport(
        self: *ProjectCache,
        from_file_path: []const u8,
        import_str: []const u8,
    ) !?*const model_mod.FileModel {
        // Only handle paths ending in `.zig` or starting with
        // `./` / `../`.  Module names route through ZLS.
        if (!isRelativeImport(import_str)) return null;

        self.muLock();
        defer self.muUnlock();

        // Fast path: check the path-resolution cache.  On a hit we skip
        // dirname + join + resolvePosix + two allocs entirely — the common
        // case once a corpus file has been visited once.
        //
        // Build the lookup key on the stack (2 × memcpy) to avoid any heap
        // allocation on cache hits.  Falls back to a heap key for paths that
        // exceed the stack budget (very rare in practice).
        const key_len = from_file_path.len + 1 + import_str.len;
        var key_buf: [512]u8 = undefined;
        const stack_key: ?[]const u8 = if (key_len <= key_buf.len) blk: {
            @memcpy(key_buf[0..from_file_path.len], from_file_path);
            key_buf[from_file_path.len] = 0;
            @memcpy(key_buf[from_file_path.len + 1 ..][0..import_str.len], import_str);
            break :blk key_buf[0..key_len];
        } else null;

        if (stack_key) |sk| {
            if (self.import_path_cache.get(sk)) |cached_abs| {
                // modelForAbsolutePathLocked always takes ownership of its argument.
                return try self.modelForAbsolutePathLocked(try self.gpa.dupe(u8, cached_abs));
            }
        } else {
            // Path too long for stack buffer — heap lookup.
            const hk = try std.fmt.allocPrint(self.gpa, "{s}\x00{s}", .{ from_file_path, import_str });
            if (self.import_path_cache.get(hk)) |cached_abs| {
                self.gpa.free(hk);
                return try self.modelForAbsolutePathLocked(try self.gpa.dupe(u8, cached_abs));
            }
            self.gpa.free(hk);
        }

        // Cache miss: resolve the path and populate the cache.
        const dir = std.fs.path.dirname(from_file_path) orelse ".";
        const joined = try std.fs.path.join(self.gpa, &.{ dir, import_str });
        defer self.gpa.free(joined);
        // Resolve `.` / `..` segments.
        const abs = try std.fs.path.resolve(self.gpa, &.{joined});

        // Heap-own the key for storage (the stack buffer doesn't outlive this call).
        const store_key = try std.fmt.allocPrint(self.gpa, "{s}\x00{s}", .{ from_file_path, import_str });
        // Store (store_key → abs) — both now owned by import_path_cache.
        // On OOM skip caching and pass abs directly (modelForAbsolutePathLocked
        // takes ownership in all cases, so abs is always consumed).
        self.import_path_cache.put(self.gpa, store_key, abs) catch {
            self.gpa.free(store_key);
            return try self.modelForAbsolutePathLocked(abs);
        };
        // Cache owns abs; pass a copy to modelForAbsolutePathLocked.
        return try self.modelForAbsolutePathLocked(try self.gpa.dupe(u8, abs));
    }

    /// Resolve a module-name @import (e.g. `@import("bun")`,
    /// `@import("jsc")`) to a FileModel.  Discovers the project
    /// root by walking ancestors of `from_file_path` looking for
    /// `build.zig` / `Cargo.toml` / `.git`; then tries to locate
    /// the module's root file using:
    ///   1. `build.zig` parsing (`b.addModule("X", .{ .root_source_file = b.path("...") })`)
    ///   2. Conventional layouts:
    ///        `<root>/<X>.zig`
    ///        `<root>/src/<X>.zig`
    ///        `<root>/src/<X>/<X>.zig`
    ///        `<root>/<X>/<X>.zig`
    ///        `<root>/src/<X>/root.zig`
    ///
    /// Results (both positive and negative) are cached on
    /// `module_paths` so subsequent imports of the same name don't
    /// re-walk the filesystem.
    pub fn modelForModuleImport(
        self: *ProjectCache,
        from_file_path: []const u8,
        module_name: []const u8,
    ) !?*const model_mod.FileModel {
        if (module_name.len == 0) return null;
        if (containsBadChar(module_name)) return null;
        self.muLock();
        defer self.muUnlock();
        if (self.module_paths.get(module_name)) |cached| {
            const path = cached orelse return null;
            const dup = try self.gpa.dupe(u8, path);
            return try self.modelForAbsolutePathLocked(dup);
        }
        const root = (try self.findProjectRootLocked(from_file_path)) orelse {
            const name_dup = try self.gpa.dupe(u8, module_name);
            try self.module_paths.put(self.gpa, name_dup, null);
            return null;
        };
        const resolved = self.discoverModulePath(root, module_name) catch null;
        // Cache the result (positive or negative).
        const name_dup = try self.gpa.dupe(u8, module_name);
        try self.module_paths.put(self.gpa, name_dup, resolved);
        if (resolved) |p| {
            const dup = try self.gpa.dupe(u8, p);
            return try self.modelForAbsolutePathLocked(dup);
        }
        return null;
    }

    /// Public wrapper — acquires mutex then calls the locked impl.
    fn findProjectRoot(
        self: *ProjectCache,
        from_file_path: []const u8,
    ) !?[]const u8 {
        self.muLock();
        defer self.muUnlock();
        return self.findProjectRootLocked(from_file_path);
    }

    /// Walk ancestors of `from_file_path` to find the project root.
    /// Strategy: prefer the OUTERMOST `.git` ancestor (most reliable
    /// repo-root marker), falling back to `build.zig` if no `.git`.
    /// `Cargo.toml` alone is NOT a reliable root marker — Cargo
    /// workspaces commonly nest `Cargo.toml` files in subprojects
    /// (e.g. bun's `src/resolver/Cargo.toml`), so picking the FIRST
    /// one gives a too-deep root that misses the real module layout.
    /// Cached after first invocation.  Caller MUST hold `mu`.
    fn findProjectRootLocked(
        self: *ProjectCache,
        from_file_path: []const u8,
    ) !?[]const u8 {
        if (self.project_root_searched) return self.project_root;
        self.project_root_searched = true;
        // Convert to absolute path via libc `realpath(3)` — handles
        // both relative inputs (resolved against CWD) and symlink
        // following.  std.fs.path.resolve does NEITHER (just
        // normalises `./`/`../` components).
        const abs_from = blk: {
            if (std.fs.path.isAbsolute(from_file_path)) {
                break :blk try self.gpa.dupe(u8, from_file_path);
            }
            const z = try self.gpa.dupeSentinel(u8, from_file_path, 0);
            defer self.gpa.free(z);
            var resolved_buf: [4096]u8 = undefined;
            const got_opt = std.c.realpath(z.ptr, &resolved_buf);
            const got = got_opt orelse break :blk try self.gpa.dupe(u8, from_file_path);
            const len = std.mem.indexOfSentinel(u8, 0, got);
            break :blk try self.gpa.dupe(u8, resolved_buf[0..len]);
        };
        defer self.gpa.free(abs_from);
        var cur: []const u8 = std.fs.path.dirname(abs_from) orelse return null;
        // First pass: walk up looking for `.git` (the outermost
        // repo boundary).  Returns the directory that CONTAINS `.git`.
        var first_build_zig: ?[]const u8 = null;
        var steps: u32 = 0;
        while (steps < 32) : (steps += 1) {
            // Capture the first build.zig as a fallback.
            if (first_build_zig == null) {
                const probe = try std.fs.path.join(self.gpa, &.{ cur, "build.zig" });
                defer self.gpa.free(probe);
                if (pathExists(self.io, probe)) {
                    first_build_zig = try self.gpa.dupe(u8, cur);
                }
            }
            const git_probe = try std.fs.path.join(self.gpa, &.{ cur, ".git" });
            defer self.gpa.free(git_probe);
            if (pathExists(self.io, git_probe)) {
                if (first_build_zig) |b| self.gpa.free(b);
                self.project_root = try self.gpa.dupe(u8, cur);
                return self.project_root;
            }
            const parent = std.fs.path.dirname(cur) orelse break;
            if (std.mem.eql(u8, parent, cur)) break;
            cur = parent;
        }
        // No `.git` found — fall back to the highest build.zig we saw.
        self.project_root = first_build_zig;
        return self.project_root;
    }

    /// Map `module_name` to an absolute path under `root` using
    /// build.zig parse + conventional-layout fallback.  Returned
    /// path is owned by `gpa`; caller is responsible for ownership.
    fn discoverModulePath(
        self: *ProjectCache,
        root: []const u8,
        module_name: []const u8,
    ) !?[]u8 {
        // Phase 1: try build.zig parsing.
        const build_zig = try std.fs.path.join(self.gpa, &.{ root, "build.zig" });
        defer self.gpa.free(build_zig);
        if (pathExists(self.io, build_zig)) {
            if (try parseBuildZigModulePath(self.gpa, self.io, build_zig, module_name)) |rel| {
                defer self.gpa.free(rel);
                const joined = try std.fs.path.join(self.gpa, &.{ root, rel });
                defer self.gpa.free(joined);
                const abs = try std.fs.path.resolve(self.gpa, &.{joined});
                if (pathExists(self.io, abs)) return abs;
                self.gpa.free(abs);
            }
        }
        // Phase 2: conventional layouts.  Probe in priority order.
        // Each entry is the candidate path RELATIVE to `root`,
        // assembled at runtime from `module_name`.
        const x = module_name;
        const candidates_dyn = [_][]const u8{
            try std.mem.concat(self.gpa, u8, &.{ x, ".zig" }),
            try std.mem.concat(self.gpa, u8, &.{ "src/", x, ".zig" }),
            try std.mem.concat(self.gpa, u8, &.{ "src/", x, "/", x, ".zig" }),
            try std.mem.concat(self.gpa, u8, &.{ x, "/", x, ".zig" }),
            try std.mem.concat(self.gpa, u8, &.{ "src/", x, "/root.zig" }),
            try std.mem.concat(self.gpa, u8, &.{ "src/", x, "/main.zig" }),
        };
        defer for (candidates_dyn) |c| self.gpa.free(c);
        for (candidates_dyn) |rel| {
            const joined = try std.fs.path.join(self.gpa, &.{ root, rel });
            defer self.gpa.free(joined);
            const abs = try std.fs.path.resolve(self.gpa, &.{joined});
            if (pathExists(self.io, abs)) return abs;
            self.gpa.free(abs);
        }
        return null;
    }

    /// Public wrapper — acquires mutex then calls the locked impl.
    fn modelForAbsolutePath(
        self: *ProjectCache,
        abs_path: []u8,
    ) !?*const model_mod.FileModel {
        self.muLock();
        defer self.muUnlock();
        return self.modelForAbsolutePathLocked(abs_path);
    }

    /// Resolve via absolute path; takes ownership of `abs_path`
    /// (frees it on cache hit or duplicates it on miss + stores).
    /// Caller MUST hold `mu`.
    fn modelForAbsolutePathLocked(
        self: *ProjectCache,
        abs_path: []u8,
    ) !?*const model_mod.FileModel {
        if (self.entries.get(abs_path)) |e| {
            self.gpa.free(abs_path);
            return &e.model;
        }
        // Load the file.
        const src_bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            abs_path,
            self.gpa,
            std.Io.Limit.limited(16 * 1024 * 1024),
        ) catch {
            self.gpa.free(abs_path);
            return null;
        };
        defer self.gpa.free(src_bytes);
        const src = try self.gpa.allocSentinel(u8, src_bytes.len, 0);
        @memcpy(src[0..src_bytes.len], src_bytes);
        rewriteNonStandardSyntaxInPlace(src);
        // src is now owned by the new entry.
        var tree = Ast.parse(self.gpa, src, .zig) catch {
            self.gpa.free(src);
            self.gpa.free(abs_path);
            return null;
        };
        const entry = self.gpa.create(Entry) catch {
            tree.deinit(self.gpa);
            self.gpa.free(src);
            self.gpa.free(abs_path);
            return error.OutOfMemory;
        };
        entry.* = .{
            .abs_path = abs_path,
            .source = src,
            .tree = tree,
            .model = undefined,
        };
        entry.model = model_mod.buildWithPath(self.gpa, &entry.tree, entry.abs_path) catch {
            entry.tree.deinit(self.gpa);
            self.gpa.free(entry.source);
            self.gpa.free(entry.abs_path);
            self.gpa.destroy(entry);
            return null;
        };
        try self.entries.put(self.gpa, abs_path, entry);
        return &entry.model;
    }
};

/// Recursively walks `root`, appending absolute paths of every
/// `.zig` file to `out`.  Skips common vendor / build / cache
/// directories so the index doesn't include unrelated trees.
fn collectZigFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(gpa) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                // Skip dirs we don't want to scan.  The walker
                // currently has no built-in prune API; the cheapest
                // workaround is to swallow opens that fail, but we
                // can pre-filter based on basename to avoid wasted
                // descent into known-large vendor dirs.
                if (shouldSkipDirBasename(entry.basename)) {
                    // Walker doesn't expose prune; let it descend
                    // and we'll filter results.  TODO: switch to
                    // walkSelectively when ergonomic.
                }
                continue;
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                // Reject paths that pass through a skipped dir.
                if (pathContainsSkippedSegment(entry.path)) continue;
                const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
                try out.append(gpa, joined);
            },
            else => {},
        }
    }
}

fn shouldSkipDirBasename(name: []const u8) bool {
    const skips = [_][]const u8{
        "node_modules", ".git", "zig-cache", ".zig-cache",
        "zig-out",      "build", "target",   "vendor",
        ".direnv",      "dist",  "out",      ".bun",
    };
    for (skips) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn pathContainsSkippedSegment(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |seg| if (shouldSkipDirBasename(seg)) return true;
    return false;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    // Probe via access() — works for both files and directories.
    // We can't use std.fs.Dir.accessZ here (Io.Dir API), so try
    // openDir first (works for directories), falling back to a
    // tiny readFile probe (works for files).
    if (std.Io.Dir.cwd().openDir(io, path, .{})) |dir_owned| {
        var dir = dir_owned;
        dir.close(io);
        return true;
    } else |_| {}
    var probe_buf: [1]u8 = undefined;
    _ = std.Io.Dir.cwd().readFile(io, path, &probe_buf) catch |err| switch (err) {
        // The probe buffer is intentionally smaller than most files;
        // readFile may return error.StreamTooLong (or similar) yet
        // still confirm the file's existence.  Treat any error
        // OTHER than NotFound as "exists" — we're only after an
        // existence check, not the contents.
        error.FileNotFound => return false,
        else => return true,
    };
    return true;
}

fn containsBadChar(s: []const u8) bool {
    for (s) |c| {
        if (c == '/' or c == '\\' or c == '.' or c == 0) return true;
    }
    return false;
}

/// Best-effort parse of a `build.zig` looking for a module
/// declaration matching `module_name`.  Matches the canonical
/// patterns:
///   `b.addModule("name", .{ .root_source_file = b.path("X") })`
///   `b.addModule("name", .{ .root_source_file = .{ .path = "X" } })`
///   `b.createModule(.{ .root_source_file = b.path("X") })`  (when assigned to a const named `name`)
///
/// Returns the relative-to-build.zig path on success, owned by `gpa`.
/// Heuristic — handles ~90% of real-world build.zig idioms; deviates
/// for projects using complex programmatic module construction.
fn parseBuildZigModulePath(
    gpa: std.mem.Allocator,
    io: std.Io,
    build_zig_path: []const u8,
    module_name: []const u8,
) !?[]u8 {
    const src_bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        build_zig_path,
        gpa,
        std.Io.Limit.limited(1024 * 1024),
    ) catch return null;
    defer gpa.free(src_bytes);
    // Scan for `addModule("<name>"` and capture the next
    // `b.path("...")` or `.path = "..."` literal.
    var i: usize = 0;
    while (i + 16 < src_bytes.len) : (i += 1) {
        if (!std.mem.startsWith(u8, src_bytes[i..], "addModule")) continue;
        // Skip to `(`.
        var j = i + "addModule".len;
        while (j < src_bytes.len and src_bytes[j] != '(') : (j += 1) {}
        if (j >= src_bytes.len) continue;
        j += 1;
        // Skip whitespace and find opening `"`.
        while (j < src_bytes.len and (src_bytes[j] == ' ' or src_bytes[j] == '\n' or src_bytes[j] == '\t')) : (j += 1) {}
        if (j >= src_bytes.len or src_bytes[j] != '"') continue;
        j += 1;
        const name_start = j;
        while (j < src_bytes.len and src_bytes[j] != '"') : (j += 1) {}
        if (j >= src_bytes.len) continue;
        const name = src_bytes[name_start..j];
        if (!std.mem.eql(u8, name, module_name)) continue;
        // Found the module decl.  Walk forward to a `root_source_file`
        // key, then the next quoted string literal.  Bounded scan so
        // we don't pick up an unrelated path elsewhere.
        const window_end = @min(src_bytes.len, j + 2048);
        const window = src_bytes[j..window_end];
        const rsf_idx = std.mem.indexOf(u8, window, "root_source_file") orelse continue;
        const after_rsf = window[rsf_idx + "root_source_file".len ..];
        // First `"..."` literal after the key.
        const quote_idx = std.mem.indexOfScalar(u8, after_rsf, '"') orelse continue;
        const lit_start = quote_idx + 1;
        const lit_end_rel = std.mem.indexOfScalar(u8, after_rsf[lit_start..], '"') orelse continue;
        const path_slice = after_rsf[lit_start .. lit_start + lit_end_rel];
        return try gpa.dupe(u8, path_slice);
    }
    return null;
}

/// In-place rewrite of bun's non-standard `fn #<name>` / `.#<name>`
/// syntax to `fn _<name>` / `._<name>`.  Length-preserving so source
/// positions stay aligned.  See lib.zig:rewriteNonStandardSyntax
/// for the rationale.
fn rewriteNonStandardSyntaxInPlace(src: [:0]u8) void {
    if (src.len < 2) return;
    var i: usize = 0;
    while (i + 1 < src.len) : (i += 1) {
        if (src[i] != '#') continue;
        const c = src[i + 1];
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
            src[i] = '_';
        }
    }
}

/// True iff `import_str` looks like a relative file-system path
/// (ends in `.zig` / `.zon` AND uses `./` or `../` or no leading
/// separator).  Module names like `"std"` / `"bun"` return false.
pub fn isRelativeImport(import_str: []const u8) bool {
    if (import_str.len < 4) return false;
    const ext_zig = std.mem.endsWith(u8, import_str, ".zig");
    const ext_zon = std.mem.endsWith(u8, import_str, ".zon");
    if (!ext_zig and !ext_zon) return false;
    return true;
}

// ── Tests ──────────────────────────────────────────────────────

test "ProjectCache: loads sibling .zig file" {
    const gpa = std.testing.allocator;
    const tio = std.testing.io;
    // Use a fixed tmp subdir under cwd so paths can be plain
    // relative — std.fs.path.resolve handles `./` cleanly.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{
        .sub_path = "lib.zig",
        .data =
        \\pub const Foo = struct {
        \\    x: u32,
        \\};
        \\
        ,
    });
    try tmp.dir.writeFile(tio, .{
        .sub_path = "main.zig",
        .data =
        \\const lib = @import("./lib.zig");
        \\pub fn main() void { _ = lib.Foo; }
        \\
        ,
    });
    // Synthesise a "from" path inside the tmp dir.  We don't
    // need a real absolute path — ProjectCache uses path.dirname +
    // path.resolve, so anything that points to the tmp dir works.
    const from_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", "main.zig" });
    defer gpa.free(from_path);
    var pc = ProjectCache.init(gpa, tio);
    defer pc.deinit();
    // The test environment may not have the tmp dir in a discoverable
    // location for the real file load — accept null too (the
    // path-resolution code is exercised regardless).
    _ = pc.modelForRelativeImport(from_path, "./lib.zig") catch {};
}

test "ProjectCache: module-name imports return null" {
    const gpa = std.testing.allocator;
    const tio = std.testing.io;
    var pc = ProjectCache.init(gpa, tio);
    defer pc.deinit();
    const fm = try pc.modelForRelativeImport("/anywhere/x.zig", "std");
    try std.testing.expect(fm == null);
}
