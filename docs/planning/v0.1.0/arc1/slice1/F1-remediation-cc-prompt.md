# CC assignment — slice-1 remediation F1: NIF upgrade callback + real coverage gate

> A focused remediation of CDC finding **F1** (`arc1/slice1/cdc-verification.md`).
> Not a new feature slice — it hardens slice 1's module so the coverage gate
> stops being a no-op. Land it **before** arc1/slice3 grows the module. CDC
> verifies on close.

## The problem (F1, restated)

`cover` instruments a module by recompiling and **reloading** it; the reload
re-runs `-on_load` → `erlang:load_nif/2` against the already-loaded NIF library.
`ERL_NIF_INIT(midiio, …, load, NULL, NULL, NULL)` supplies **no `upgrade`
callback**, so that reload fails, `cover` cannot instrument `midiio.beam`, and the
gate was neutered to `--min_coverage=0` (`rebar.config`). Net: the `check` alias's
coverage step is currently a no-op, and every later slice inherits a disabled
gate. (Captured as a learning in `docs/NIF-LEARNINGS.md` L13.)

## Goal

1. Module reload succeeds — so `cover` can instrument `midiio.beam`.
2. `min_coverage` is raised from `0` to a **real floor the current tests
   actually meet**, so the gate has teeth.
3. No behavioural regression: all slice-1 eunit tests still pass; ASan still
   clean; no leaked/double-created mutex or resource type across the reload.

## Required reading

- `arc1/slice1/cdc-verification.md` (finding F1) and `arc1/slice1/ledger.md`
  (row 15 caveat).
- NIF concept cards — **authoritative, read before writing the C**:
  `knowledge/erlang/concept-cards/otp-erts/nif-lifecycle.md` (load/upgrade/unload
  contract) and `.../nif-resources.md` (resource type takeover on upgrade).
- The current `c_src/midiio_nif.c` (`load` at `:91`, `enif_open_resource_type` at
  `:96`, the static `g_ctx_res_type` / `g_uninit_lock` / atoms) and `rebar.config`
  (the `coverage` alias).

## What to do

- Add an **`upgrade`** callback to `ERL_NIF_INIT` and implement it per the
  `nif-lifecycle` card. Key mechanics to get right (verify against the cards, do
  **not** write them from memory):
  - The resource type already exists from the prior code instance, so opening it
    in `upgrade` must use **`ERL_NIF_RT_TAKEOVER`** (not `RT_CREATE`) — or a
    create-or-takeover flag combination — so it inherits rather than fails/dupes.
  - Do **not** double-create or leak the mutex / re-evaluate the atoms in a way
    that corrupts state across the reload; reason about what the module-level
    statics (`g_ctx_res_type`, `g_uninit_lock`, the `am_*` atoms) mean across an
    upgrade (the NIF `.so` persists; the BEAM module is what reloads). Factor the
    shared init so `load` and `upgrade` don't diverge.
  - Decide `reload`/`unload` deliberately (likely leave `reload` NULL; `unload`
    only if you allocate something that must be freed on final unload).
- Raise the coverage floor in `rebar.config`: replace `--min_coverage=0` with a
  real threshold. **Report the coverage % the current tests actually achieve**,
  then set the floor just below it (a small margin for hard-to-hit error lines
  like `alloc_failed`). Do not pick a number from the air; derive it from the
  measured result. If a couple of lines are genuinely untestable, say which and
  why rather than inflating the threshold or adding a contrived test.

## Out of scope (track, don't bundle)

- **F2** (gate the test-only NIFs `result_atom/1`/`uninit_count/0` behind
  `-DMIDIIO_TEST`) and **F3** (document the `rebar3 as test check` invocation) are
  separate, tracked items — leave them for their own follow-up unless one falls
  out for free. Keep this remediation tight: upgrade callback + real coverage.

## Done

`rebar3 as test check` green with a **non-zero** `min_coverage` that the tests
meet; `cover` actually instruments `midiio.beam` (coverage report shows real
line data, not "cannot cover"); all slice-1 eunit tests pass; ASan harness still
`ASAN-OK`. Update `arc1/slice1/ledger.md` row 15's caveat to reflect the now-real
gate, with a short amendment note. Five-iteration cap.

## Ledger

See `F1-remediation-ledger.md`.
