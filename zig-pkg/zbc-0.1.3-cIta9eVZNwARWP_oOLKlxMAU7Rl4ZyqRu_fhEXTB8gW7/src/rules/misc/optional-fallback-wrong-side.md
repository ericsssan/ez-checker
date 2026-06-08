# optional-fallback-wrong-side

`self.remoteSettings orelse self.localSettings` uses the wrong
fallback direction.  `remoteSettings` is what the peer advertised;
when absent (null), the code falls back to `localSettings`, which
is the locally-configured security limit.  This silently relaxes
the check when the peer hasn't sent SETTINGS yet.

Real-world: oven-sh/bun#31129, h2_frame_parser.zig.

## Why this matters

In protocol implementations, peer-advertised values and
locally-configured limits serve different roles:

- **Remote / peer / advertised** fields hold values the other side
  sent.  They can be null when the peer hasn't sent the relevant
  message yet (e.g. HTTP/2 SETTINGS frame).
- **Local / own / configured** fields hold locally-enforced limits.
  They should be the authoritative value when the remote hasn't
  provided one.

Using `peerValue orelse ownValue` in a comparison check means:
"use the peer's value; if absent, fall back to our own limit."
This is backwards — when the peer hasn't sent a value, the check
should use the local limit unconditionally, not fall back to
another peer field.

## Canonical bug

```zig
// HTTP/2 frame validation
const limit = self.remoteSettings orelse self.localSettings;
if (frame_size > limit) return error.FrameTooLarge;
```

When `remoteSettings` is null (peer hasn't sent SETTINGS yet), this
falls back to `localSettings` — but `localSettings` is our own
configured value, not a security limit we should relax.  The intent
is likely `self.localSettings` unconditionally.

## Fix

Use the locally-configured limit directly when the peer value is
absent, or restructure to use the remote value only as an override:

```zig
// Use local limit when remote not set
const limit = self.localSettings;

// Or: use remote only if stricter
const limit = @min(self.localSettings, self.remoteSettings orelse std.math.maxInt(u32));
```

## Detection

Token-level heuristic: matches `recv.field_A orelse recv.field_B`
where both sides use the same receiver and `field_A` / `field_B`
have opposing semantic-pole prefixes:

| field_A prefix | field_B prefix |
|---|---|
| `remote` | `local` |
| `peer` | `own` |
| `client` | `server` |
| `external` | `internal` |
| `advertised` | `configured` |

Prefix matching is case-insensitive.  The `orelse` must be the
standard Zig `orelse` keyword.  The RHS must also be a
`recv.field` access on the same receiver — bare default values
(e.g. `self.remoteValue orelse 0`) do not fire.
