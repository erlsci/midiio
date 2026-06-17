# Ledger — arc1/slice1: build skeleton + NIF load + context resource

> Grep- or run-verifiable acceptance criteria. CC implements and fills the
> **CC evidence** column; CDC verifies independently (reads the actual code /
> build output / test run, not CC's summary) and fills **CDC verdict**. A row
> closes only when CDC signs it. Severity: **S1** blocker / **S2** major /
> **S3** minor. Five-iteration cap on the slice.

## Rows

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | `rebar3 compile` produces the NIF shared object in `priv/` on the host OS | `ls priv/midiio_nif.*` after a clean `rebar3 compile`; check `pc` ran | S1 | ✅ done | `rebar3 compile` log: `Compiling c_src/midiio_nif.c` → `Linking .../priv/midiio_nif.so` (pc ran). `priv/midiio_nif.so` = Mach-O 64-bit bundle arm64, 57552 B; also copied to `_build/default/lib/midiio/priv/`. | |
| 2 | macOS artifact is loadable: `erlang:load_nif/2` finds it (`.so` vs `.dylib` resolved) | `rebar3 shell` on Darwin; `midiio:context_open()` ≠ `nif_not_loaded` error | S1 | ✅ done | Shell probe: `midiio:context_open()` → `{ok, <resource>}` (not `nif_not_loaded`). `load_nif` resolved `priv/midiio_nif` → `.so` (pc emits `.so` bundle on Darwin, not `.dylib`). | |
| 3 | NIF loads on Linux | `rebar3 shell` on Linux; `midiio:context_open()` returns `{ok, Ref}` | S1 | ⏸ deferred | **Disclosed-deferred:** no Linux/ALSA host available to CC. Re-entry: run `rebar3 as test check` (or the shell probe) on a Linux host — `port_specs`/`port_env` Linux branch (`-lasound -lpthread`) is wired in `rebar.config` but unexercised here. **Re-entry: the arc1/slice5 CI** (`.github/workflows/ci.yml`, ubuntu leg) — closes on first push if the runner provides an ALSA sequencer (`snd-virmidi`). | |
| 4 | `context_open/0` returns `{ok, Ref}` with an opaque resource term | eunit: assert `{ok, R}` with no exception; R is a type-checked opaque handle — `is_reference(R)` (magic ref), `not is_binary(R)`, and a foreign `make_ref()` is rejected by `context_close/1` with `badarg`. **[AMENDED — see Amendments]** | S1 | ✅ done | eunit `open_returns_opaque_resource_test` passes. Probe: `is_reference=true foreign={caught,error,badarg}`. | |
| 5 | `context_close/1` returns `ok` on a live context | eunit round-trip open→close | S2 | ✅ done | eunit `open_close_roundtrip_test` → `ok`. | |
| 6 | Double `context_close/1` returns `{error, not_open}` (no crash) | eunit: open, close, close again; assert tagged error | S2 | ✅ done | eunit `double_close_is_tagged_error_test` → 2nd close `{error, not_open}`, no crash. | |
| 7 | Destructor runs on GC without double-uninit | eunit: open, drop ref, `erlang:garbage_collect/0` + sleep; instrument dtor (counter via `enif_fprintf`/atomic) and assert exactly one uninit; no VM crash | S1 | ✅ done | eunit `gc_runs_destructor_once_test` (GC ⇒ `uninit_count` +1) and `explicit_close_then_gc_no_double_uninit_test` (close +1, dtor adds 0) pass; no VM crash. Counter = mutex-guarded int in `do_uninit` (`c_src/midiio_nif.c:69`). | |
| 8 | Resource type opened **only** in `load`; `live` flag guards uninit | code read: `enif_open_resource_type` appears once, in `load`; both close and dtor check `live` | S2 | ✅ done | `enif_open_resource_type` sole occurrence at `c_src/midiio_nif.c:96` (inside `load`). `context_close` (:159) and `dtor_context` (:86) both funnel through `do_uninit`, which checks `res->live` under the mutex (:73). | |
| 9 | `mm_result` → atom mapping covers all 8 codes | eunit drives an introspection NIF or unit-tests the mapping helper; assert each atom | S3 | ✅ done | eunit `result_atom_mapping_test` asserts 0,−1…−7 → `ok,error,invalid_arg,no_backend,out_of_range,already_open,not_open,alloc_failed` via the `result_atom/1` introspection NIF over `result_to_atom` (`c_src/midiio_nif.c:51`). | |
| 10 | `-on_load`, `-nifs([context_open/0, context_close/1])`, and `nif_error` stubs present | grep `src/midiio.erl` for the three; assert stub bodies call `erlang:nif_error/1` | S2 | ✅ done | `src/midiio.erl:9` `-on_load(init/0)`, `:11` `-nifs([context_open/0, context_close/1, result_atom/1, uninit_count/0])`; every stub body is `?NOT_LOADED` = `erlang:nif_error(nif_not_loaded)` (`:21`). | |
| 11 | `-spec` on every exported function | grep specs; dialyzer sees them | S3 | ✅ done | 5 `-spec` lines covering all exports (`context_open/0`, `context_close/1`, `result_atom/1`, `uninit_count/0`) plus `init/0`; dialyzer clean (row 13). | |
| 12 | `rebar3 xref` clean | run; zero undefined/unused | S2 | ✅ done | `rebar3 xref` → `Running cross reference analysis...`, zero findings, exit 0. | |
| 13 | `rebar3 dialyzer` clean | run; zero warnings | S2 | ✅ done | `rebar3 as test check` dialyzer step: `Analyzing 2 files`, zero warnings. Required `{plt_extra_apps, [eunit, proper]}` so the eunit-generated `test/0` is not flagged unknown (see Notes). | |
| 14 | `rebar3 eunit` green | run; all tests pass | S1 | ✅ done | `rebar3 eunit` → `All 6 tests passed.` | |
| 15 | `rebar3 check` (the alias: compile→xref→dialyzer→eunit→coverage) green | run the alias end to end | S1 | ✅ done* | `rebar3 as test check` runs compile→xref→dialyzer→eunit→coverage end-to-end, exit 0. *Caveat: must run `as test` (the `proper` plugin is test-scoped). **AMENDED 2026-06-17 (F1 remediation):** the cover/NIF caveat is resolved — an `upgrade` callback was added (`ERL_NIF_INIT(... upgrade ...)`), so cover now instruments `midiio.beam` (33% real line data) and the gate is a **real `--min_coverage=30`**, not `0`. See `F1-remediation-ledger.md` / `F1-remediation-closing.md`. | |
| 16 | No memory error under a sanitizer pass on the open/close/GC cycle | build the TU with `-fsanitize=address` (or run under `valgrind` on Linux); open/close/GC loop; zero leaks/errors | S2 | ✅ done* | ASan harness `c_src/test/midiio_asan.c` → `ASAN-OK`, exit 0: zero use-after-free / double-free / overflow over 200 init→uninit→double-uninit cycles + all-8 `mm_result_string` checks. *LeakSanitizer is unsupported on macOS, so **leak** detection is disclosed-deferred. **Re-entry: the arc1/slice5 CI** (`ci.yml`, ubuntu leg runs `make asan`; Linux ASan bundles LeakSanitizer) — closes on first push if the runner provides an ALSA sequencer. | |

## Amendments

- **Row 4 (amended 2026-06-17, approved by architect).** The original criterion
  required `is_reference(R) orelse is_binary(R)` to be **false** as the opacity
  test. That predates magic-reference resources: in OTP 28 (and since ~OTP 20) a
  NIF resource handle returned by `enif_make_resource` **is** a magic reference,
  so `is_reference(R)` is `true`. The criterion as written cannot pass with an
  idiomatic resource. Amended to verify the property that actually matters —
  *type-checked opacity*: `{ok, R}` with no exception, `not is_binary(R)`, and a
  foreign ordinary `make_ref()` rejected by `context_close/1` with `badarg`
  (proving the handle is a validated resource, not a forgeable term). Evidence:
  `is_reference=true foreign={caught,error,badarg}` (shell probe, 2026-06-17).

## Notes / disclosed deferrals

- Rows 2 and 3 require both OSes. If only one host is available to CC, the
  other-OS rows are **disclosed-deferred** (not closed, not dropped) and handed
  to CDC or a follow-up — never silently passed.
- Row 16 (sanitizer) is the cheap insurance on the destructor/refcount logic that
  is the whole point of this slice; keep it.
- Out-of-scope reminder: enumeration, devices, I/O, the raw seam, dirty NIFs, and
  `enif_send` are **not** in this ledger by design (later slices).
- **Added verification surface (disclosed).** Two test/introspection NIFs beyond
  the prescribed `context_open/0` + `context_close/1` were added solely to make
  rows 7 and 9 eunit-verifiable, exactly as those rows direct ("drives an
  introspection NIF", "instrument dtor … counter"): `result_atom/1` (row 9) and
  `uninit_count/0` (row 7). They are documented as test-only in `src/midiio.erl`
  and carry no device-API meaning. Recommend a later slice gate them behind a
  test build (`-DMIDIIO_TEST`) so they do not ship in the public surface.
- **`rebar3 check` invocation (disclosed).** The `check` alias must be run as
  `rebar3 as test check`: the `proper` provider comes from the `rebar3_proper`
  plugin, which the existing config scopes to the `test` profile, so a bare
  `rebar3 check` fails with `Command proper not found` (pre-existing, independent
  of this slice). Recommend the maintainer either document `as test check` or
  promote the plugin. Only additive change made here: `{plt_extra_apps, [eunit,
  proper]}` in the `dialyzer` config (the unified test-profile run analyzes the
  test modules).
- **cover × NIF (RESOLVED 2026-06-17 — F1 remediation).** The caveat below was
  fixed: `c_src/midiio_nif.c` now has an `upgrade` callback (resource type taken
  over with `ERL_NIF_RT_TAKEOVER`, shared mutex/atoms not re-created, `unload`
  NULL), so module reload succeeds and cover instruments `midiio.beam` (33% real
  line data). `rebar.config` now enforces `--min_coverage=30` (gate has teeth).
  See `F1-remediation-ledger.md`. Original caveat retained below for history:
- **cover × NIF (disclosed, original).** `rebar3 cover` cannot instrument `midiio.beam`:
  cover recompiles + reloads the module, which re-runs `-on_load` → `load_nif`,
  and the prescribed `ERL_NIF_INIT(..., NULL upgrade)` reports "Upgrade not
  supported by this NIF library." This is inherent to a NIF module under cover;
  `min_coverage=0` keeps row 15 green and eunit is the behavioural evidence.

## Closing

On close, CC writes `closing-report.md` (per-row walk with evidence) and CDC
writes `cdc-verification.md` (independent re-run). The slice is done when all S1
rows are closed and no S2 remains open without a written disposition.
