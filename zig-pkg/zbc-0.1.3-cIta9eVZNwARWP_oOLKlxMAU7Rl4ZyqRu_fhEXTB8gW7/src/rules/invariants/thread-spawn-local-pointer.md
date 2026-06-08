# thread-spawn-local-pointer

`Thread.spawn(.{}, fn, .{ &local, ... })` — passing the address of a
function-local variable into a spawned thread.  The thread's lifetime
is independent of the spawning function; when the spawning function
returns the local dies, and the thread reads or writes through a
dangling pointer.

## Example

Incorrect:

    pub fn process(data: []const u8) !void {
        var ctx: Context = .{ .data = data, .done = false };
        const t = try std.Thread.spawn(.{}, worker, .{&ctx});  // ← &ctx escapes
        t.detach();
        // `ctx` dies here; `worker` may still be running
    }

Fix — heap-allocate the context and transfer ownership:

    pub fn process(data: []const u8) !void {
        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);
        ctx.* = .{ .data = data, .done = false };
        const t = try std.Thread.spawn(.{}, worker, .{ctx});
        t.detach();
        // worker owns ctx now and must free it
    }

Or, if the spawning function must outlive the thread, use `defer thread.join()`:

    pub fn process(data: []const u8) !void {
        var ctx: Context = .{ .data = data };
        const t = try std.Thread.spawn(.{}, worker, .{&ctx});
        defer t.join();   // guarantees ctx outlives the thread
        doOtherWork();
    }

## When this might be a false positive

The rule only fires on `&<single-identifier>` locals.  Field addresses
(`&self.field`) and index expressions are not flagged here — they are
handled by the existing stack-escape rule.

## Related

- **stack-escape** — returning a pointer to a local variable.
- **publish-then-touch-self** — using `self`/`this` after publishing to
  a concurrent queue.
