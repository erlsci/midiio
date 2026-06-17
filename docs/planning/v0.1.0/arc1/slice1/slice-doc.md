# arc1/slice1 — build skeleton + NIF load + context resource

> Plan-of-record for the slice. The thinnest end-to-end vertical that retires the
> toolchain and resource-model risk before any device I/O. Parent: `ARCS.md`
> (Arc 1). Design refs: `DESIGN.md` §2 (resources), §6 (error mapping), §8
> (build). NIF mechanics: concept cards `erl-nif`, `nif-resources`,
> `nif-loading`, `nif-thread-safety`.

## Goal

`rebar3 compile` builds and loads a NIF on the host OS; an Erlang caller can
`context_open/0` → get an opaque resource → `context_close/1`, and a dropped
handle runs the destructor (`mm_context_uninit`) without double-free. Nothing
else — no enumeration, no devices, no I/O.

## Why this is slice 1

It isolates the single biggest unknown — *does `pc` build and load a NIF cleanly
under this rebar3 on macOS and Linux, and does the resource/destructor lifecycle
behave* — into the smallest possible diff. Everything downstream (devices,
send/recv) assumes this works; proving it first means later slices iterate on
behavior, not toolchain.

## Scope

**In:** vendored `c_src/minimidio.h`; `c_src/midiio_nif.c` (one TU,
`MINIMIDIO_IMPLEMENTATION`); `midiio_context` resource type opened in `load`;
`context_open/0`, `context_close/1`; `result_string`→atom mapping; `-on_load`
+ stubs; `pc` build wiring + per-OS `port_specs`; eunit.

**Out (later slices):** enumeration + caps (arc1/slice2); device resources and
all I/O (arc2+); the raw seam; dirty NIFs; `enif_send`. The registry context
(§2) arrives in slice 2 with enumeration — slice 1's context is a plain per-call
context.

## Key risks called out for the implementer

- **macOS artifact extension.** `erlang:load_nif/2` takes the path *without*
  extension; confirm `pc` emits an artifact `load_nif` actually finds on Darwin
  (`.so` vs `.dylib`). This is the most likely toolchain snag.
- **Destructor vs. explicit close double-uninit.** `mm_context_uninit` guards on
  `initialized`, but the resource must track its own `live` flag so an explicit
  `context_close/1` followed by GC-triggered destructor does not uninit twice.
- **`-nifs/1` attribute (OTP 27).** Declare the NIF-backed functions so the
  stubs aren't optimized away and Dialyzer is informed.

## Acceptance

The slice is done when every row in `ledger.md` is closed with evidence and
`rebar3 check` (compile → xref → dialyzer → eunit → coverage) is green on macOS
and Linux. CDC verifies independently against the actual build output and test
run, not this document.
