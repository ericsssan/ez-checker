# owned-field-no-outer-cleanup

A struct has a value-typed field whose type (declared in the same
file) exposes a cleanup method (`deinit` / `close` / `destroy` /
`free` / `stop` / `finalize` / `dispose`) — but the outer struct
itself exposes NO cleanup method.  Users who treat the outer as a
plain value silently leak the inner's owned non-memory resource
(file handle, socket, ref, mmap) when the outer goes out of scope.

This is the complement to
[`missing-deinit-on-composed-owner`](missing-deinit-on-composed-owner.md):

- *That* rule fires when `Outer.deinit` EXISTS but FORGETS to
  call `<self>.<field>.deinit(...)`.
- *This* rule fires when `Outer.deinit` is MISSING entirely.

Same family of bugs (resource leak via composition); different
source signal.

## Bad

```zig
const FileHandle = struct {
    fd: i32,
    pub fn close(self: *FileHandle) void { _ = self; }
};

const Session = struct {
    handle: FileHandle,  // owns an OS file handle
    name: []const u8,
    // No deinit / close / etc. — caller has no way to release
    // `handle.fd` when a Session value is dropped.
};
```

## Good

```zig
const FileHandle = struct {
    fd: i32,
    pub fn close(self: *FileHandle) void { _ = self; }
};

const Session = struct {
    handle: FileHandle,
    name: []const u8,
    pub fn deinit(self: *Session) void {
        self.handle.close();
    }
};
```

## Why pointer / slice fields are excluded

The "owned pointer" vs "borrowed pointer" distinction isn't
visible at the type level in Zig — `*Inner` could be a borrow OR
an owned heap pointer.  Treating all pointer fields as owned
would produce many false positives.  Value-typed fields
(including `?T` optional values) are the cleanest "I own this"
signal.

## Only one report per struct

If `Outer` has multiple qualifying fields, the rule fires once
per outer (the first qualifying field).  The design gap is the
SAME: `Outer` exposes no cleanup, regardless of how many of its
fields need one.
