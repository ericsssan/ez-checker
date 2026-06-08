# arena-escape

Returning a value whose storage lives inside a function-local
arena.  The arena dies with the frame, so the caller would read
freed memory.

## Example

Incorrect — the returned slice points into the arena's bump
memory, which is freed by the `defer` before the caller receives
the value:

    pub fn render(self: *Self) []const u8 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        return std.fmt.allocPrint(arena.allocator(), "{}", .{self.id})
            catch return "";
    }

Fix — use a caller-owned allocator (take one as a parameter), or
return a value type that doesn't borrow from the arena:

    pub fn render(self: *Self, alloc: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(alloc, "{}", .{self.id})
            catch return "";
    }

## When this might be a false positive

- The arena is moved into a struct field on the return value
  (composite ownership transfer).  If zbc can't see the move
  through your construction code, the embedded borrow still flags;
  reshape so the move is via a recognised constructor name
  (`init` / `create` / `new` / `open`), or suppress the line with
  `// zbc-disable-line:arena-escape`.

## Related

- `arena-use-after-kill`: the same conceptual error, but the use
  happens INSIDE the function rather than past return.
- `stack-escape`: returning a pointer to a stack local — same idea
  with a different storage class.
