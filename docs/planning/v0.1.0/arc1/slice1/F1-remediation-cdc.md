# CDC verification — slice-1 F1 remediation

> Independent code read of the F1 changes (`c_src/midiio_nif.c` upgrade path,
> `rebar.config` gate). Verdict: **PASS, no findings.** Commit `483b648`.

## Signed by code read

- **Upgrade callback present + correct (rows 1, 2).** `ERL_NIF_INIT(midiio,
  nif_funcs, load, NULL, upgrade, NULL)` (`:263`); `load`→`init_statics(…,
  ERL_NIF_RT_CREATE)`, `upgrade`→`init_statics(…, ERL_NIF_RT_TAKEOVER)`
  (`:133–147`). `RT_TAKEOVER` is the correct flag for inheriting an existing
  resource type across a same-`.so` BEAM reload (nif-lifecycle / nif-resources).
- **No double-init / leak across reload (row 3).** `init_statics` is the single
  shared path; the mutex is created only `if (g_uninit_lock == NULL)` (reused on
  takeover, `:114`), atoms re-derived idempotently, and `unload` stays NULL. The
  block comment (`:89–104`) reasons correctly about *why*: the `.so` persists and
  the statics are shared across module instances, so freeing them on an
  old-instance purge would dangle the live instance. This is the subtle part and
  it's right.
- **Gate has real teeth (rows 4–6).** `min_coverage` 0 → 30, measured 33%; CC
  proved floor=40 fails / 30 passes. The 4 uncovered lines are the `nif_error`
  stub bodies — correctly identified as unreachable-by-construction, not inflated
  with contrived tests.
- **No regression (rows 7–9).** 6/6 eunit, ASan `ASAN-OK`, `rebar3 as test check`
  green.

## CDC note (not a finding — a learning)

The 33% figure is an artifact of a NIF module's shape: the Erlang side is mostly
unreachable stub bodies and the real logic is in C, which BEAM `cover` can't see.
The floor (30) is a sound *reachable-line* gate, but the BEAM % is **not** the
coverage story for this code — the C is covered by the ASan harness + behavioural
eunit. Captured as `NIF-LEARNINGS.md` L17 for the eventual guide.

## Still-tracked (unchanged by this remediation)

F2 (gate the test-only NIFs behind `-DMIDIIO_TEST`) and F3 (document the `as test`
invocation) remain open, as instructed — not regressions, just deferred hygiene.
