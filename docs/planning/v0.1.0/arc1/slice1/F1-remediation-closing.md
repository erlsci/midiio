# Closing report — slice-1 remediation F1: NIF upgrade callback + real coverage gate

> CC's note on the fix. CDC re-checks the gate is genuinely enforced (not
> re-zeroed) and the upgrade path doesn't leak. Host: macOS arm64, OTP 28.
> Date: 2026-06-17. Iteration: 1.

## The fix

**C (`c_src/midiio_nif.c`).** Added an `upgrade` callback so a BEAM-module reload
(cover instrumentation, or a hot upgrade) re-runs `load_nif` successfully instead
of failing on the missing callback. The load/upgrade init is factored into one
`init_statics(env, flags)` so the two paths can't diverge:

- `load` → `init_statics(env, ERL_NIF_RT_CREATE)`.
- `upgrade` → `init_statics(env, ERL_NIF_RT_TAKEOVER)` — the new module instance
  **takes over** the existing `midiio_context` resource type (inherits existing
  resources; its dtor applies to them) rather than re-creating it.
- The mutex is created only `if (g_uninit_lock == NULL)` (reused on takeover, not
  re-created → no leak/dangle); atoms are re-derived idempotently (same global
  immutable values).
- `ERL_NIF_INIT(midiio, nif_funcs, load, NULL, upgrade, NULL)` — `unload` stays
  **NULL** on purpose: the `.so` persists and the statics are *shared* across
  module instances, so freeing the mutex when an old instance is purged would
  dangle the live instance.

Mechanics taken from the `nif-lifecycle` and `nif-resources` cards, not memory.

**Build (`rebar.config`).** Added `{cover_enabled, true}` to the `test` profile so
eunit produces real coverdata, and raised the gate `--min_coverage=0` →
`--min_coverage=30`.

## Measured coverage (derived, not guessed)

`midiio.beam` = **33%** (total 33%), from `eunit.coverdata` (+ `proper.coverdata`).
Per-line:

- **Covered:** `init/0` (`src/midiio.erl:26–27`).
- **Uncovered (4 lines):** the `?NOT_LOADED` = `erlang:nif_error(nif_not_loaded)`
  bodies of `context_open/0`, `context_close/1`, `result_atom/1`, `uninit_count/0`
  (`:32,38,44,50`). These are **unreachable by construction** — once the `.so`
  loads, the C NIFs replace the function bodies, so the Erlang stub lines never
  execute. They exist only as the pre-load failsafe + Dialyzer signal. Covering
  them would require calling the functions before the NIF loads, which defeats
  their purpose; not faked with a contrived test.

Floor set at **30** (just below the measured 33, per the prompt's small margin).
2/6 coverable lines is the honest maximum for this NIF-stub module.

## Verification

- `rebar3 as test check` → **exit 0**: compile → xref → dialyzer → eunit (6/6) →
  coverage (33% ≥ 30). No "Upgrade not supported / Cover compilation failed".
- Gate has teeth: `--min_coverage=40` → exit 1 (fails); `--min_coverage=30` →
  exit 0. So it is enforced, not a no-op.
- `rebar3 eunit` → All 6 tests pass (suite unchanged — no behavioural regression).
- ASan harness → `ASAN-OK`, exit 0 (rebuilt against the new TU).

## Ledger / tracking

- `F1-remediation-ledger.md`: 10/10 rows done.
- `arc1/slice1/ledger.md` row 15 + the cover×NIF note amended (dated) to reflect
  the now-real gate.
- `docs/NIF-LEARNINGS.md` L13 resolved: the speculative caveat replaced with
  the implemented `init_statics`/`RT_TAKEOVER` Good example and the outcome.

## Out of scope (still tracked, not bundled)

- **F2** — gate the test-only NIFs (`result_atom/1`, `uninit_count/0`) behind a
  test build. Untouched here.
- **F3** — document the `rebar3 as test check` invocation. Untouched here.
