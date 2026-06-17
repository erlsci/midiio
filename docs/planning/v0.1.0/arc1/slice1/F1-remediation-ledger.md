# Ledger — slice-1 remediation F1: NIF upgrade callback + real coverage gate

> CC implements + fills **CC evidence**; CDC verifies independently. Severity:
> **S1** blocker / **S2** major / **S3** minor. Five-iteration cap.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | `ERL_NIF_INIT` declares an `upgrade` callback (no longer `NULL`) | code read: 5th macro arg is the upgrade fn; the fn exists | S1 | ✅ done | `c_src/midiio_nif.c:235` → `ERL_NIF_INIT(midiio, nif_funcs, load, NULL, upgrade, NULL)`; `upgrade` defined at `:140`. | |
| 2 | The resource type is taken over on upgrade, not re-created | code read: `upgrade` opens `midiio_context` with `ERL_NIF_RT_TAKEOVER` (or create-or-takeover); cite the `nif-resources`/`nif-lifecycle` mechanics followed | S1 | ✅ done | `upgrade` (`:140`) → `init_statics(env, ERL_NIF_RT_TAKEOVER)` (`:146`); `init_statics` (`:105`) opens `midiio_context` with the passed flag (`load` uses `RT_CREATE` `:137`). Follows `nif-lifecycle` ("take over an existing resource type … inherit existing objects; the new library's dtor is used for inherited objects") and `nif-resources`. | |
| 3 | No double-create / leak of the mutex or atoms across reload | code read + reasoning: shared init factored so `load`/`upgrade` don't double-init `g_uninit_lock` or corrupt the `am_*` atoms; statics-vs-reload reasoning stated | S2 | ✅ done | `init_statics` creates the mutex only `if (g_uninit_lock == NULL)` (`:114–117`) — reused on takeover, not re-created. Atoms re-derived idempotently (same global immutable values). `unload` left `NULL` (`:235`) because the `.so` persists and the statics are shared across instances — freeing them on old-instance purge would dangle the live instance. Reasoning in the block comment `:89–104`. | |
| 4 | `cover` actually instruments `midiio.beam` | run coverage; the cover report shows **real line coverage** for `midiio`, not a "cannot cover / not instrumented" notice | S1 | ✅ done | `rebar3 as test check` cover analysis: `midiio 33%`, `total 33%` from `_build/test/cover/eunit.coverdata` (+`proper.coverdata`). No "Upgrade not supported / Cover compilation failed" warning. Per-line: L26–27 covered (1,0); L32/38/44/50 uncovered (0,1). | |
| 5 | `min_coverage` raised from 0 to a real floor the tests meet | `rebar.config` `coverage` alias has `--min_coverage=N` with `N` > 0; the measured coverage ≥ `N` | S1 | ✅ done | `rebar.config:75` → `{cover, "-v --min_coverage=30"}`; measured 33% ≥ 30. Gate has teeth: floor=40 → exit 1 (fails); floor=30 → exit 0. `{cover_enabled, true}` added to the test profile (`:58`) so eunit produces the coverdata. | |
| 6 | Achieved coverage % reported; any untestable lines named | CC states the measured % and the floor chosen, and justifies any deliberately-uncovered lines (e.g. `alloc_failed` path) rather than inflating | S3 | ✅ done | Measured **33%** (2/6 coverable lines); floor **30** (just below, per prompt). Covered: `init/0` (`src/midiio.erl:26–27`). Uncovered (4): the `?NOT_LOADED` = `erlang:nif_error(nif_not_loaded)` stub bodies of `context_open/0,context_close/1,result_atom/1,uninit_count/0` (`:32,38,44,50`) — **unreachable by construction**: once the `.so` loads, the C NIFs replace these bodies, so they never execute. Not inflated with contrived tests. | |
| 7 | No behavioural regression — all slice-1 eunit tests pass | `rebar3 eunit` → all tests pass (the 6 existing + any added) | S1 | ✅ done | `rebar3 eunit` → `All 6 tests passed.` (unchanged suite). | |
| 8 | ASan harness still clean | `c_src/test/midiio_asan.c` → `ASAN-OK`, exit 0 | S2 | ✅ done | Rebuilt + ran → `ASAN-OK`, exit 0. | |
| 9 | `rebar3 as test check` green end-to-end with the real gate | run the alias; exit 0 with `min_coverage` > 0 enforced | S1 | ✅ done | `rebar3 as test check` → exit 0, compile→xref→dialyzer→eunit(6)→coverage(33% ≥ 30) all green; `min_coverage=30` enforced (teeth proven, row 5). | |
| 10 | slice-1 ledger row 15 caveat updated | `arc1/slice1/ledger.md` row 15 amended to reflect the now-real coverage gate, with a dated amendment note | S3 | ✅ done | `arc1/slice1/ledger.md` row 15 + Amendments updated (2026-06-17): cover/NIF caveat superseded by F1 remediation; gate now real at `min_coverage=30`. | |

## Notes

- The upgrade-path C mechanics (`ERL_NIF_RT_TAKEOVER`, what module-level statics
  mean across a BEAM-module reload while the `.so` persists) are exactly the kind
  of detail to take from the `nif-lifecycle` / `nif-resources` cards rather than
  from memory. If a subtlety can't be resolved cleanly, surface it (disclosed
  deferral) rather than guessing.
- This remediation feeds `docs/NIF-LEARNINGS.md`: confirm/expand L13 (the
  `cover`/`on_load`/upgrade gotcha) with the concrete fix that worked, and add the
  `ERL_NIF_RT_TAKEOVER` detail as a GOOD example.
- Out of scope: F2 (test-NIF gating) and F3 (`as test` docs) — tracked separately.

## Closing

On close, CC notes the fix in a short closing report; CDC re-checks that the gate
is genuinely enforced (not re-zeroed) and that the upgrade path doesn't leak.
