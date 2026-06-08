# reset-skips-pooled-resource-release

A struct exposes both `deinit` and `reset` methods.  `deinit`
calls release/free/destroy/close on owned external handles
(typically pool slots, OS handles, or other allocator-managed
resources).  The sibling `reset` either does nothing for those
handles or only zeros the struct.  Callers using `reset` to
recycle the struct leave the underlying pool / sub-allocator
slots still held → silent capacity leak.

## Why this matters

`reset` and `deinit` should be lifecycle siblings: `deinit` is
"end of life," `reset` is "back to initial state, ready for
re-use."  Either one must release all externally-owned
resources; what differs is whether the struct's own backing
storage is freed.

A `reset` that forgets to release pool slots will eventually
exhaust the pool — and because the pool's free list is the
*owning* side, the leak doesn't show up in standard `gpa.deinit()`
leak checks.  The symptom is "after N reset cycles, the pool
runs out" — far from the cause.

2 PRs in TigerBeetle alone touched this same shape
(tigerbeetle/tigerbeetle#3436, #1734), suggesting the asymmetry
is invisible during code review because deinit and reset are
often hundreds of lines apart in source.

## Canonical bug (tigerbeetle/tigerbeetle#3436)

```zig
const SegmentedArray = struct {
    nodes: []*Node,
    node_count: usize,

    pub fn deinit(self: *SegmentedArray, allocator: Allocator, node_pool: *NodePool) void {
        for (self.nodes[0..self.node_count]) |node|
            node_pool.release(node);            // releases pool slots
        allocator.free(self.nodes);
    }

    pub fn reset(self: *SegmentedArray) void {
        self.node_count = 0;                    // BUG: pool slots still held
    }
};
```

## Fix

Mirror the pool-release loop in `reset`:

```zig
pub fn reset(self: *SegmentedArray, node_pool: *NodePool) void {
    for (self.nodes[0..self.node_count]) |node|
        node_pool.release(node);
    self.node_count = 0;
}
```

## Why the detector is precise

- Limited to structs that have BOTH `deinit` and `reset` defined
  as sibling methods — the asymmetry is what makes the bug.
- Cleanup-method allowlist: `release`, `free`, `destroy`,
  `close`, `deinit`, `unref`, `deref` — common Zig std + custom
  pool / refcount idioms.
- Comparison is on `<recv>.<method>` pairs: a cleanup is
  considered "present in reset" only if the SAME receiver
  identifier AND SAME method name appears.  This catches the
  common shape `<pool>.release(...)` vs missing `<pool>.release(...)`.
- Receiver-aware: `allocator.free(self.nodes)` in deinit and
  `allocator.free(other_thing)` in reset both count as
  `allocator.free` — the rule cares that the cleanup TYPE
  appears, not the exact argument.

Limitations (deliberate):
- Only compares the FIRST `deinit` and FIRST `reset` per struct.
  Overloaded variants are out of scope.
- Doesn't try to reason about what cleanups SHOULD be in reset
  (e.g., a reset that intentionally KEEPS its allocator-managed
  state isn't easily distinguished).
