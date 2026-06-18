# Closing report — arc2/slice1: output device resource + lifecycle

> CC's per-row walk with evidence (full table in `ledger.md`). CDC verifies
> independently. Host: macOS arm64 (CoreMIDI, 15 destinations present), OTP 28.
> Date: 2026-06-17. Iteration: 1. **No send** — that's slice 2.

## What was built

The per-device-context model (DESIGN §2 / arc-2 ⚑): a `midiio_device` resource
that **embeds its own `mm_context`** — no shared registry context, no
cross-resource keep.

- **C (`c_src/midiio_nif.c`):**
  - `typedef struct { mm_context ctx; mm_device dev; int live; } midiio_dev_res;`
    and a `g_dev_res_type` opened in `init_statics` with the passed flag (so it
    rides the F1 `load`/`upgrade` path like `midiio_context`).
  - `open_output(Index)`: per-device legible context name (`"midiio-out:<Index>"`)
    → `mm_context_init` → `mm_out_open`. **Partial-failure cleanup:** if the port
    open fails after the context initialised, `mm_context_uninit` before
    releasing — never leak a context. `live` set only when both succeed.
  - `do_dev_cleanup`: one mutex-guarded path, `mm_out_close` (**port first** — it
    references the context) then `mm_context_uninit`, flips `live`, bumps the
    shared `uninit_count`. Both `close/1` and `dtor_device` funnel through it, so
    an explicit close followed by GC does not double-free.
  - `open_output_virtual/0`: test scaffolding (virtual source, no destination)
    so the lifecycle is exercisable headlessly. Not a public virtual-port API.
- **Erlang (`src/midiio.erl`):** `open_output/1`, `close/1` (+ the test
  `open_output_virtual/0`) with `-nifs`/`-export`/`-spec`/stubs; opaque
  `-type device() :: term().` distinct from `context()`.
- **Tests:** 7 new eunit cases (out-of-range, opacity+badarg, close, double-close,
  GC-destructor-once, close-then-GC-no-double, real-hardware open) → **19 total**;
  ASan harness extended with the device lifecycle loop **and** a partial-failure
  loop.

## Disposition

All 16 ledger rows **done**, evidenced. Highlights:

- **Lifecycle (rows 3–6, 8, 9):** verified deterministically via the virtual
  output (headless-safe) and the `uninit_count` counter — the device destructor
  reclaims both the port and the per-device context exactly once; double-close →
  `{error, not_open}`; cleanup order is port-then-context under one `live` guard.
- **Partial-failure (row 7):** the `out_open`-failed branch uninits the context;
  a dedicated **ASan forced-failure loop** (out-of-range `mm_out_open`) shows no
  leak — not just a code read.
- **Memory safety (rows 8, 16):** `make asan` → `ASAN-OK` over success,
  double-close, and partial-failure loops (×200 each).
- **Real hardware (row 12):** `open_output(0)` → `{ok, Dev}`, `close` → `ok` on
  this macOS box (15 destinations).
- **Gate (row 15):** `rebar3 as test check` green; coverage stays **dormant**
  (`midiio` excluded per slice-5 item 1) — the new NIF stubs did **not** require
  any floor change. This is exactly why the binding module was excluded.

## Disclosed / deferred

- **Linux/ALSA `mm_out_open` path:** verified by code read on CC's macOS box; the
  arc1/slice5 CI (`ci.yml`, ubuntu leg) exercises it on push if the runner
  provides a sequencer — same re-entry as the other deferred-Linux rows.
- **No silent drops.** `send` (slice 2), the raw seam, dirty NIFs, inbound/recv,
  input devices, UMP, batch, and a *public* virtual-port API are out of scope and
  untouched.
