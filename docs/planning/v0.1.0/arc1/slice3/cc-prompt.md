# CC assignment — arc1/slice3: device enumeration + capabilities

> Self-contained. Read the slice doc + design refs, then implement to the ledger.
> CDC verifies independently on close. **Prerequisite:** the slice-1 F1
> remediation (real coverage gate) should be in before this lands.

## Posture

Peer-frame, write-to-the-floor. Load **collaboration-framework** and
**erlang-guidelines**. NIF term-building (maps, binaries, lists) comes from the
substrate cards, not memory: `knowledge/erlang/concept-cards/otp-erts/erl-nif.md`
and `.../erlang-otp-action/erl-nif-api.md`. This slice is **read-only discovery**
— no device open, no I/O, no threads, no dirty NIFs, no `enif_send`.

## Required reading (evidence)

1. `docs/planning/v0.1.0/arc1/slice3/slice-doc.md` — surface, the three risks.
2. `docs/planning/v0.1.0/DESIGN.md` — §1 (surface), §5 (index is display-only,
   not identity), §2 (the registry-context note — *not* needed this slice; see
   below), R6 (expose backend atom + caps).
3. `c_src/midiio_nif.c` (slice 1) — the load callback, the context resource, the
   atom-pre-making pattern, the `result_to_atom` helper to follow for style.
4. `c_src/minimidio.h` — the enumeration + caps API:
   `mm_in_count`/`mm_out_count` (`:559,561`), `mm_in_name`/`mm_out_name`
   (`:560,562`), `mm_context_caps` (`:557`) and the `MM_CAP_*` flags (`:334–340`).

## What to build

Add to `c_src/midiio_nif.c` and `src/midiio.erl`:

```erlang
-spec list_inputs(context())  -> [{non_neg_integer(), binary()}].
-spec list_outputs(context()) -> [{non_neg_integer(), binary()}].
-spec caps(context())         -> #{backend := atom(), midi1 := boolean(),
                                    ump := boolean(), midi2 := boolean(),
                                    virtual_in := boolean(), virtual_out := boolean()}.
```

**`list_inputs/1` / `list_outputs/1`:**
- `enif_get_resource` the context (badarg on a foreign term — same pattern as
  `context_close/1`).
- Loop `0 .. mm_in_count(ctx)-1`; for each, `mm_*_name(ctx, idx, buf, sizeof buf)`
  into a fixed stack buffer (256 bytes); build a `binary()` from the actual
  string length; emit `{Index, NameBin}`. Return the list (build it head-first or
  reverse to keep ascending index order — your call, just keep it ascending).
- If a name lookup returns non-success for an in-range index, still include the
  entry with whatever string minimidio wrote (don't drop it — that desyncs the
  index). Document the behaviour.

**`caps/1`:**
- `mm_context_caps(ctx)` → bitset; decode each `MM_CAP_*` flag to a boolean map
  value.
- `backend` is a **compile-time** atom chosen by the platform macro
  (`MM_BACKEND_COREMIDI`→`coremidi`, `_WINMM`→`winmm`, `_ALSA`→`alsa`,
  `_WEBMIDI`→`webmidi`). Pre-make these atoms (and the map-key atoms) in `load`.
- Build the map with `enif_make_new_map` + `enif_make_map_put` (or the
  appropriate term API per the cards).

**Erlang side:** add `-nifs`/`-export` entries and `nif_error` stubs for the three,
each with a `-spec`. Keep the opaque `context()` type.

## Notes / decisions

- **Registry context is NOT needed here.** DESIGN §2's singleton registry context
  is for the per-device-context model in arc 2; this slice enumerates against the
  context the caller already opened with `context_open/0`. (On ALSA that context
  carries a live `seq` handle, which enumeration needs; on CoreMIDI enumeration is
  context-free but still takes the handle. Either way: use the passed-in `Ctx`.)
- **No normalization, no caching.** Return what minimidio reports, freshly each
  call. Index is display-only.

## Constraints (erlang-guidelines)

- `-spec` every export; snake_case; `{ok,_}`-style not needed here (these return
  plain lists/maps, no failure mode beyond badarg on a bad handle — let that
  crash).
- Atoms pre-made in `load` (incl. the new backend + map-key atoms); never build
  atoms from untrusted input.
- NIFs stay well under 1 ms (enumeration of a handful of ports is trivial) — not
  dirty.

## Out of scope (do not build)

Opening/closing devices, send/recv, the raw seam, virtual ports, UMP, the
registry context, hotplug notifications. Those are later slices/arcs.

## Done = every ledger row closed with evidence; `rebar3 as test check` green with
the real coverage gate. Disclose any deferral; don't silently drop. Five-iteration
cap.
