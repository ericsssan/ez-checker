# asymmetric-field-free

A type defines two or more fields with the **same declared type** (a
strong signal they hold the same kind of resource), and its
destructor — `deinit` / `finalize` / `destroy` — operates on some
of them but omits the others.  Whichever side the destructor skips
leaks its allocation on every instance, because the field still
holds a heap pointer at drop time.

The "same declared type" check is what distinguishes this from a
generic destructor-completeness rule: scalar fields (`bool`, ints)
often legitimately go unmentioned, and singleton heap fields are
caught by the existing `heap-leak` rule.  Sibling-pair asymmetry
is the smoking gun.

## Example

Incorrect — both fields are `?QueryStringMap`, but `deinit` only
unwraps and frees one:

    pub const MatchedRoute = struct {
        query_string_map: ?QueryStringMap = null,
        param_map: ?QueryStringMap = null,

        pub fn deinit(this: *MatchedRoute) void {
            if (this.query_string_map) |*map| {
                map.deinit();
            }
            // ← missing: if (this.param_map) |*map| map.deinit();
        }
    };

Fix:

    pub fn deinit(this: *MatchedRoute) void {
        if (this.query_string_map) |*map| {
            map.deinit();
        }
        if (this.param_map) |*map| {
            map.deinit();
        }
    }

## When this might be a false positive

- The omitted field is intentionally an alias / borrow of the
  handled one (same type, but only one side owns).  Declare the
  borrowed side as a pointer type (`*T`); the rule skips pointer-
  typed fields automatically.  Otherwise suppress with
  `// zbc-disable-line:asymmetric-field-free`.
- The omitted field is freed via a helper called from inside the
  destructor (`this.cleanupParamMap();`).  zbc doesn't follow the
  helper; inline the free or rename the helper to match the
  destructor-mentions pattern (e.g. add a stray `_ = this.<field>;`
  comment-style line).

## Related

- `heap-leak`: catches the type-level version where a heap-allocated
  type's destructor doesn't free `self` at all.
- `clobbered-by-struct-reset`: a different per-call-site leak where
  a struct-literal reset drops a previously-assigned field.
