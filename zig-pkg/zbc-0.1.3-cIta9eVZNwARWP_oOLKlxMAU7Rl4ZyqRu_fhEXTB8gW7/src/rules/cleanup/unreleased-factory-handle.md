# unreleased-factory-handle

`const <X> = [try] <device>.<create-method>(...);` returns a
refcounted handle with initial refcount=1.  The fn body has NO
`defer <X>.release()` AND the handle isn't returned or stored as
a struct field.  One ref leaks per call.

## Why this matters

GPU APIs (webgpu, sysgpu, Metal, Vulkan-via-wrapper) return
freshly-counted resources from their `create*` methods.  Each
returned handle owns one reference; the caller must transfer
ownership (return, store in a field, pass to a constructor that
takes ownership) OR release the ref before scope exit.

The leak is invisible per-call — the resource is fully usable
within the fn body — but it shows up as descriptor-pool
exhaustion or GPU memory pressure after many invocations.  In
example code (which often demonstrates one-shot rendering) the
leak doesn't surface; in production use (a renderer that
creates buffers per frame) it does.

Distinct from [`unreleased-refs-on-error`](unreleased-refs-on-error.md):
- That rule catches LOOP-side `manager.reference()` addrefs
  without paired release errdefer (on the error path).
- This rule catches HAPPY-path `device.create*()` returns
  without paired `defer release`.

## Canonical bug (hexops/mach example)

```zig
pub fn setupPipeline(device: *gpu.Device) void {
    const layout = device.createPipelineLayout(.{ ... });
    // ... use `layout` as input to createRenderPipeline ...
    // BUG: no `defer layout.release();` and `layout` doesn't escape
}
```

## Fix

```zig
const layout = device.createPipelineLayout(.{ ... });
defer layout.release();
// ... use layout transiently ...
```

Or transfer ownership explicitly:

```zig
self.pipeline_layout = device.createPipelineLayout(.{ ... });
```

## Why the detector is precise

- Create-method allowlist is narrow: only GPU-flavored factory
  methods (`createShaderModule`, `createPipelineLayout`,
  `createBindGroup`, `createBuffer`, ..., `getQueue`,
  `acquireCurrentTexture`).
- Skip if the fn body contains `defer <X>.<release>()` /
  `errdefer <X>.<release>()` where release ∈ {`release`,
  `deinit`, `destroy`, `deref`, `unref`}.
- Skip if the handle "escapes":
  - `return <X>;` (or `return ... <X> ...`)
  - `<self>.<field> = <X>;` (struct-field assignment, single or
    multi-segment receiver)
- Skip non-GPU receivers (the rule's allowlist filters by method
  name, which is GPU-specific).

Limitations (deliberate):
- Doesn't track `<X>` passed as an argument to another method
  that conventionally takes ownership (e.g., `bundle_encoder.setPipeline(X)`).
  Such fns SHOULD addref on receive; if they don't, this is
  their bug, not the caller's.  Out of scope for this rule.
- Doesn't track aliasing — `var y = X; defer y.release();` would
  release X's ref, but the rule looks specifically for
  `defer <X>.release()` syntax.
