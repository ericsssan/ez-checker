# fd-write-after-close

A `const|var <X> = try <dir>.<opener>(...);` binds an OS file
handle (`createFile`, `openFile`, `openDir`, `open`, `openat`,
`accept`, `socket`, and their `Z` variants).  `<X>.close();`
invalidates the handle.  Any subsequent use of `<X>` — a method
call (`writeAll`, `read`, `sync`, `seekTo`, …) OR a field access
(`<X>.handle`) — reads or writes through a dangling file
descriptor.

## Why this matters

- **POSIX fd-reuse hazard**: the kernel may reassign the closed fd
  number to an unrelated `open()` from another thread before the
  dangling write lands.  The stale write then goes to a completely
  different file — silently corrupting data in something the
  attacker can influence.  This is a real security-relevant bug
  class, not just a correctness one.
- **Windows handle invalidation**: the handle becomes
  `INVALID_HANDLE_VALUE`-equivalent and the call fails — but the
  failure mode is a bare error that most code doesn't distinguish
  from "real" I/O errors.
- **Async runtimes**: in `std.Io`-style frameworks the closed fd
  may already be in another I/O group's submission queue when
  reused; the kernel then services the queued request against the
  new fd.

## Canonical bug

```zig
const file = try dir.createFile("output.txt", .{});
file.close();
try file.writeAll(payload);   // ← dangling fd write
```

The `close()` releases the fd back to the kernel.  Any subsequent
`writeAll` reads `file.handle` (still pointing at the now-released
fd number) and calls `write(2)` against it.  Under load on a
multi-threaded process the fd may already point at a different
file by the time the syscall runs.

## Fix

Use `defer file.close();` immediately after opening (the canonical
RAII shape), OR — if you genuinely want explicit `close()` — make
it the LAST use of the handle in scope:

```zig
// (a) RAII (preferred):
const file = try dir.createFile("output.txt", .{});
defer file.close();
try file.writeAll(payload);

// (b) Explicit close as the last statement:
const file = try dir.createFile("output.txt", .{});
try file.writeAll(payload);
file.close();
```

## Why the detector is precise

- Binding shape is narrow: `const|var <X> = [try] <recv>.<opener>(`
  with a single-identifier receiver.  Cross-module openers
  (`std.fs.cwd().createFile(...)` is a chained receiver) are out
  of scope for the first cut.
- `close` calls inside `defer` / `errdefer` are skipped — they
  fire at scope exit, AFTER every other use in scope; not a UAF.
- `close` calls inside nested blocks (catch/if/loop bodies) are
  skipped — they don't always execute, and the use that follows
  is on the non-close path.
- Use-lookup is bounded by the binding's enclosing scope — a
  shadowed `file` in a sibling loop capture doesn't count.

This is the third member of the borrow-then-invalidate family
([[hashmap-getptr-rehash]], [[arraylist-items-slice]]); same
precision template applied to OS file handles.
