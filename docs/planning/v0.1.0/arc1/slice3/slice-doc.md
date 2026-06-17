# arc1/slice3 — device enumeration + capabilities

> Plan-of-record. Parent: `ARCS.md` (Arc 1). Design refs: `DESIGN.md` §1 (surface),
> §5 (device identity — index is display-only), §2 (registry-context note), and
> the R6 commitment (expose backend atom + caps). Builds on slice 1's context
> resource; **assumes the slice-1 F1 remediation has landed** (real coverage gate).

## Goal

Given an open context (slice 1's `context_open/0`), an Erlang caller can:

- `midiio:list_inputs(Ctx)` / `midiio:list_outputs(Ctx)` → a list of
  `{Index, Name}` for the MIDI ports currently visible;
- `midiio:caps(Ctx)` → a map naming the **backend** and its **capability flags**.

No device is opened, no I/O occurs — this is read-only discovery. It's the last
foundation slice before outbound transport (arc 2).

## Surface

```erlang
-spec list_inputs(context())  -> [{Index :: non_neg_integer(), Name :: binary()}].
-spec list_outputs(context()) -> [{Index :: non_neg_integer(), Name :: binary()}].
-spec caps(context()) -> #{backend     := coremidi | winmm | alsa | webmidi,
                           midi1       := boolean(),
                           ump         := boolean(),
                           midi2       := boolean(),
                           virtual_in  := boolean(),
                           virtual_out := boolean()}.
```

- **Names are `binary()`** (UTF-8), built from minimidio's name buffer. Whatever
  minimidio writes is what we return (e.g. CoreMIDI's `"(unknown)"` on a lookup
  miss) — no normalization.
- **Index is a snapshot ordinal**, display/enumeration only — it shifts on
  hotplug and is **not** identity (DESIGN §5). The stable handle arrives with
  `open_*` in arc 2.
- **`backend`** is a compile-time atom (minimidio picks the backend by platform
  macro); **caps** decode `mm_context_caps` (`MM_CAP_*`) into booleans. Exposing
  the backend atom is the R6 commitment — `midi` needs it to know the vel-0 quirk
  regime, which `MM_CAP_*` alone doesn't convey.

## Why a map for caps

A decoded map (`#{backend => alsa, virtual_in => true, ...}`) is friendlier and
more dialyzer-legible than a raw bitset, and lets `midi` pattern-match the one
field it cares about (`backend`) without bit math.

## Key risks / decisions for the implementer

- **Name buffer sizing.** Use a generous fixed buffer (minimidio's examples use
  128; 256 is safe). `mm_*_name` writes a NUL-terminated string; build the binary
  from its actual length, not the buffer size.
- **Enumeration in headless CI.** `mm_in_count`/`mm_out_count` may be **0** (no
  devices) on CI runners — that's not a failure. Tests assert the *shape* (a list,
  possibly empty) and that `caps` returns the correct per-OS backend + virtual
  flags. Populated enumeration is a manual/hardware check (or arrives with the
  virtual-loopback test in arc 3).
- **Name-lookup failures.** If `mm_*_name` returns non-success for an index in
  range, include the entry with whatever name minimidio produced (don't silently
  drop a port — that would desync index↔reality). Document the choice.
- **Map construction at the NIF boundary** (`enif_make_new_map` /
  `enif_make_map_put`, atom keys pre-made in `load`) — take the term-building API
  from the substrate, not memory.

## Acceptance

Every row in `ledger.md` closed with evidence; `rebar3 as test check` green
(with the real coverage gate from the F1 remediation). CDC verifies independently.
