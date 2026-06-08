# double-optional-ptr

`?*?T` — a doubly-optional pointer type. For nullable out-parameters the correct type is `?*T` (nullable pointer to T) or `*?T` (non-null pointer to optional T). The form `?*?T` is almost always a copy-paste error where one `?` was accidentally duplicated.

## What the rule checks

The rule fires on the 4-token pattern `? * ? identifier` — any occurrence of `?*?T` in the source. This pattern is unusual in correct Zig code; the vast majority of nullable-out-parameter declarations use `?*T` (nullable pointer) or `*?T` (pointer to optional).

## Why it matters

`?*?T` declares a type with two levels of optionality:
- The outer `?` makes the pointer itself nullable
- The inner `?` makes the pointee an optional

When used as an out-parameter, writing through the pointer fills an `Optional(T)` struct in the caller's memory, not a plain `T`. The caller expects a `?*T` (so that `result.*` gives them a `T`), but instead receives a `?*?T` (so that `result.*` gives them a `?T`). The discriminant byte of the inner optional is written at the address the caller considers the start of their `T` value, corrupting the caller's data.

In practice:
1. The out-parameter store writes `Optional(T) { .tag = ..., .value = ... }` where the caller only expects `T`
2. The caller's subsequent read of `result.*` as `T` reads the discriminant byte as the first field of `T`
3. The rest of `T`'s data is never initialized — reading it is undefined behaviour

## Real-world instance

- **oven-sh/bun#13955** (`napi_open_escapable_handle_scope`): the out-parameter was typed `?*?napi_escapable_handle_scope` instead of `?*napi_escapable_handle_scope`. Writing through the pointer filled the inner optional's discriminant byte at the address the caller considered the start of their handle scope, corrupting the caller's stack. Fix: removed the inner `?`.

## Fix

```zig
// Instead of (doubly-optional — almost always wrong):
extern fn napi_open_escapable_handle_scope(
    env: napi_env,
    result: ?*?napi_escapable_handle_scope,
) napi_status;

// For a nullable out-parameter (pointer may be null; write T on success):
extern fn napi_open_escapable_handle_scope(
    env: napi_env,
    result: ?*napi_escapable_handle_scope,
) napi_status;

// For a non-null out-pointer that writes an optional (e.g. query by key):
fn findEntry(map: *Map, key: Key, out: *?Value) void { ... }
```
