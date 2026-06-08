# unreleased-refs-on-error

A loop body acquires refcounted references via `<obj>.<addref>()`
(where `addref ∈ {reference, retain, addRef, addref}`), and the
enclosing fn has a later `try` expression with NO `errdefer`
containing a release-class method call (`release`, `deref`, `unref`,
`removeRef`).  Every reference taken in the loop leaks if that later
`try` propagates its error.

## Why this matters

Refcounted resources don't have a Zig-level destructor that the
compiler can wire up — the rule "you took a ref, you owe a release"
is enforced only by code.  An `errdefer` registered before a fallible
operation is the canonical place for the matching release.  Without
it, every retry of the failing fallible op leaks one ref per loop
iteration; these accumulate silently until the underlying refcount
becomes unrecoverable (OOM on a GPU descriptor pool, Vulkan/D3D
validation crash, ObjC zombie objects).

The bug is *path-specific*: success leaves no trace.  Only the
fallible-error path leaks, so the symptom shows up rarely and far
from the cause — exactly the shape escape-analysis tools should
catch.

## Canonical example (hexops/mach sysgpu/vulkan.zig PipelineLayout.init)

```zig
pub fn init(device: *Device, desc: *const sysgpu.PipelineLayout.Descriptor) !*PipelineLayout {
    var group_layouts = try allocator.alloc(*BindGroupLayout, desc.bind_group_layout_count);
    errdefer allocator.free(group_layouts);              // ← frees slice, not refs

    const set_layouts = try allocator.alloc(vk.DescriptorSetLayout, desc.bind_group_layout_count);
    defer allocator.free(set_layouts);
    for (0..desc.bind_group_layout_count) |i| {
        const layout: *BindGroupLayout = @ptrCast(@alignCast(desc.bind_group_layouts.?[i]));
        layout.manager.reference();                       // ← refcount ↑ (LEAK SITE)
        group_layouts[i] = layout;
        set_layouts[i] = layout.vk_layout;
    }

    const vk_layout = try vkd.createPipelineLayout(...);  // ← fallible: leak path 1
    const layout = try allocator.create(PipelineLayout);  // ← fallible: leak path 2
    ...
}
```

If either of the post-loop `try` calls returns an error, the existing
`errdefer allocator.free(group_layouts)` reclaims the slice's heap
bytes but never releases the N BindGroupLayout references taken in
the loop.  Each such error leaks N refs.

## Fix

Add a release-class errdefer registered immediately after the loop
(or use a running counter the errdefer reads):

```zig
var taken: usize = 0;
errdefer for (group_layouts[0..taken]) |l| l.manager.release();
for (0..desc.bind_group_layout_count) |i| {
    const layout = ...;
    layout.manager.reference();
    group_layouts[i] = layout;
    set_layouts[i] = layout.vk_layout;
    taken += 1;
}
const vk_layout = try ...;
```

The errdefer fires only on the error path; on success the references
remain with the constructed pipeline layout, which takes them over.

## Why the detector is precise

- Addref method list is narrow: `reference`, `retain`, `addRef`,
  `addref` — `ref` is excluded as too generic (collides with command-
  buffer "borrow a sub-reference" usage).
- The fn must contain a `try` somewhere (proxy for "returns an error
  union" — a fn with no `try` can't take the error path the rule
  describes).
- Any errdefer in the fn body containing a release-class call
  (`release` / `deref` / `unref` / `removeRef`) suppresses the
  report.  Over-broad on the suppression side keeps FPs at zero.
- The `try` must come *after* the loop in lexical order — only the
  post-loop fallible op exposes the leak path the rule describes.
