# arc2/slice1 — output device resource + lifecycle

> Plan-of-record. Parent: `arc2/arc-plan.md`. Lands the per-device-context model
> (D2, concretized) and the crashing-owner-leaks-nothing guarantee. **No send** —
> that's slice 2. Design refs: `DESIGN.md` §1, §2, §6; the resource/upgrade pattern
> from the slice-1 F1 work.

## Goal

An Erlang caller can `open_output(Index)` → get an opaque device handle → `close`
it, and a dropped handle runs a destructor that closes the OS port **and** uninits
the device's own context, exactly once, with no leak. Each device is isolated in
its own `mm_context`.

## Surface

```erlang
-spec open_output(Index :: non_neg_integer()) -> {ok, device()} | {error, atom()}.
-spec close(device())                          -> ok | {error, not_open}.
%% device() — opaque midiio_device resource handle (distinct from context())
```

## The model (from the arc plan)

The `midiio_device` resource **embeds its own `mm_context`**:
`{ mm_context ctx; mm_device dev; int live; }`. `open_output` does
`mm_context_init(&r->ctx, Name)` then `mm_out_open(&r->ctx, &r->dev, Index)`; the
destructor (and explicit `close`) does the `live`-guarded
`mm_out_close(&r->dev)` → `mm_context_uninit(&r->ctx)`. No cross-resource keep —
the context is part of the device resource. (Index is a global ordinal.)

## Key decisions / risks for the implementer

- **Resource type registration** mirrors `midiio_context`: open `midiio_device` in
  `init_statics` with the passed flag (`RT_CREATE` on load, `RT_TAKEOVER` on
  upgrade) so it survives the F1 upgrade path.
- **`live` flag + single cleanup path** (mirror `do_uninit` from slice 1): one
  guarded function does `mm_out_close` then `mm_context_uninit`, flips `live`, so
  explicit `close` followed by GC-destructor does not double-free. Order matters:
  close the **port first** (it references the context), then uninit the context.
- **Partial-failure cleanup in `open_output`:** if `mm_context_init` succeeds but
  `mm_out_open` fails, uninit the context before returning `{error, _}` (don't
  leak a context). Set `live` only once both succeed.
- **Per-device context name:** give each context a legible, distinct name
  (e.g. `"midiio-out:<Index>"`) so devices aren't 16 identical system clients.
- **`close/1` is the unified close** — it operates on the `midiio_device` resource
  (output now; input devices reuse it in arc 3). A foreign/bad handle → `badarg`.
- **Error mapping:** `mm_out_open` → `MM_OUT_OF_RANGE` (`{error, out_of_range}`),
  `MM_ERROR` (`{error, error}`), `MM_INVALID_ARG` (`{error, invalid_arg}`).

## Testing notes

- **Deterministic (headless-safe):** `open_output(VeryHighIndex)` →
  `{error, out_of_range}`; `close(make_ref())` → `badarg`.
- **Lifecycle without hardware:** prefer a deterministic open via a **virtual
  output port** (`mm_out_open_virtual`, which needs no destination) *as test
  scaffolding only* to exercise the resource/destructor path (open → drop → GC →
  exactly-one context uninit via the `uninit_count` counter; no double-free).
  *(Using a virtual port internally for a test is acceptable — same pattern the
  arc-3 loopback will use — even though virtual ports aren't a public v0.1.0
  feature.)* If that proves awkward, fall back to a real-hardware open on macOS +
  code-read for the rest, and disclose.
- **Real hardware (macOS):** `open_output(0)` against a present destination →
  `{ok, Dev}`; `close` → `ok`; double `close` → `{error, not_open}`.
- **ASan:** extend the harness to cover the device lifecycle (init → out_open via
  a virtual port → out_close → uninit, looped) — zero leaks/use-after-free.

## Acceptance

Every ledger row closed or disclosed-deferred; `rebar3 as test check` green; the
device destructor provably reclaims both the port and the per-device context with
no double-free. CDC verifies.
