# CC assignment — arc2/slice1: output device resource + lifecycle

> Self-contained. Read the arc plan + slice doc, then implement to the ledger.
> **No send in this slice** (that's arc2/slice2). CDC verifies on close.

## Posture

Peer-frame, write-to-the-floor. Load **collaboration-framework** and
**erlang-guidelines**. NIF resource/lifecycle mechanics from the substrate cards
(`otp-erts/nif-resources.md`, `nif-lifecycle.md`, `nif-thread-safety.md`), not
memory. Reuse the slice-1 patterns already in `c_src/midiio_nif.c` (the
`do_uninit` single-guarded-cleanup-path, `init_statics` with the load/upgrade
flag, atom pre-making).

## Required reading

1. `docs/planning/v0.1.0/arc2/arc-plan.md` — the device/context model (D2
   concretized; the ⚑ decision) and the slice breakdown.
2. `docs/planning/v0.1.0/arc2/slice1/slice-doc.md` — surface, model, risks, tests.
3. `c_src/midiio_nif.c` — the existing `midiio_context` resource, `init_statics`,
   `do_uninit`/`live` pattern, `result_to_atom`.
4. `c_src/minimidio.h` — `mm_context_init` (`:555`), `mm_out_open` (`:580`),
   `mm_out_close` (`:584`), `mm_out_open_virtual` (`:589`); read the CoreMIDI
   (`:890`) + ALSA (`:1630`) `mm_out_open`/`mm_out_close` bodies to confirm
   `dev->ctx=ctx` and that `mm_out_close` disposes only the port.

## What to build

**C (`c_src/midiio_nif.c`):**
- A `midiio_device` resource: `typedef struct { mm_context ctx; mm_device dev;
  int live; } midiio_dev_res;`. Open the resource type in `init_statics` with the
  passed flag (alongside `midiio_context`), so both `load` (`RT_CREATE`) and
  `upgrade` (`RT_TAKEOVER`) register it.
- `open_output(Index) -> {ok, Dev} | {error, Atom}`: `enif_alloc_resource`;
  `mm_context_init(&r->ctx, name)` where `name` is a legible per-device string
  (e.g. `"midiio-out:<Index>"`); on success `mm_out_open(&r->ctx, &r->dev,
  Index)`; on **both** success set `live=1`, `enif_make_resource` +
  `enif_release_resource`, return `{ok, Dev}`. **Partial-failure cleanup:** if
  `out_open` fails after `context_init` succeeded, `mm_context_uninit(&r->ctx)`
  before releasing + returning `{error, result_to_atom(r)}`.
- `close(Dev) -> ok | {error, not_open}`: `enif_get_resource` (badarg on a foreign
  term); a single guarded cleanup (mirror `do_uninit`) that, under a mutex if you
  share one, does `mm_out_close(&r->dev)` **then** `mm_context_uninit(&r->ctx)`,
  flips `live`; returns `ok` if it ran, `{error, not_open}` if already closed.
- Device destructor: the same guarded cleanup (so GC after an explicit close does
  not double-free).
- Register `open_output/1` + `close/1` in `nif_funcs`.

**Erlang (`src/midiio.erl`):** add `-nifs`/`-export`/`nif_error` stubs + `-spec`
for `open_output/1` and `close/1`; add an opaque `-type device() :: term().`
(distinct from `context()`).

## Constraints

- snake_case; `-spec` every export; `{ok,_}`/`{error,atom()}`.
- Atoms pre-made in `init_statics`; never from runtime input.
- `mm_context_init`/`mm_out_open` are fast OS calls — **not** dirty (the dirty
  send is slice 2).
- Cleanup order: **port before context** (the device references the context).
- Let a genuinely bad handle crash with `badarg`; map predictable failures to
  `{error, atom()}`.

## Out of scope (do not build)

`send` (slice 2), the raw seam, dirty NIFs, inbound/recv/`enif_send`, input
devices' `open_input`/`start`/`stop`, UMP, batch, public virtual ports. (You may
use `mm_out_open_virtual` **internally for a deterministic lifecycle test** — see
the slice doc — but do not expose a virtual-port API.)

## Done

Every ledger row closed or disclosed-deferred with a re-entry note; `rebar3 as
test check` green (coverage gate stays dormant — `midiio` excluded; the device
NIFs are more stubs, which is exactly why we excluded it); ASan clean over the
device lifecycle. Five-iteration cap.
