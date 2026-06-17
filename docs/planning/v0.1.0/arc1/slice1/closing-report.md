# Closing report — arc1/slice1: build skeleton + NIF load + context resource

> CC's per-row walk with evidence. CDC verifies independently against the actual
> code / build output (not this summary) and writes `cdc-verification.md`.
>
> Host: macOS (Darwin 24.6, arm64), Erlang/OTP 28, erts 16.4, rebar3 3.27,
> CoreMIDI backend. Date: 2026-06-17. Iteration: 1.

## What was built

| Artifact | Role |
|----------|------|
| `c_src/minimidio.h` | Vendored upstream header (sha-identical to `workbench/minimidio/minimidio.h`), the in-tree compile location. |
| `c_src/midiio_nif.c` | Single NIF translation unit: `load`, `dtor_context`, `context_open/0`, `context_close/1`, the `do_uninit` lifecycle helper, the `mm_result`→atom mapping, and the `result_atom/1` + `uninit_count/0` test NIFs. |
| `src/midiio.erl` | `-module/-on_load/-nifs`, NIF loader, `erlang:nif_error/1` stubs, `-spec` on every export, opaque `context()` type. |
| `rebar.config` | `pc` plugin + provider hooks, per-OS `port_specs`/`port_env`, `artifacts`, `plt_extra_apps`. Existing xref/dialyzer/proper/check config preserved. |
| `test/midiio_tests.erl` | eunit suite (6 tests) closing rows 4–9. |
| `c_src/test/midiio_asan.c` | Standalone ASan harness for the C lifecycle layer (row 16). |

## Per-row walk

- **Row 1 — compile produces `priv/midiio_nif.so` (S1): done.** Clean `rebar3
  clean && rebar3 compile` logs `Compiling c_src/midiio_nif.c` → `Linking
  …/priv/midiio_nif.so` (pc ran). Artifact: Mach-O 64-bit bundle arm64, 57552 B,
  reproduced from clean.
- **Row 2 — macOS loadable, `.so`/`.dylib` resolved (S1): done.** pc emits a
  `.so` bundle on Darwin (not `.dylib`); `load_nif("…/midiio_nif", 0)` resolves
  it. Shell probe: `midiio:context_open()` → `{ok, <resource>}`, not
  `nif_not_loaded`. This was the slice's flagged top risk; it is retired.
- **Row 3 — loads on Linux (S1): DEFERRED.** No Linux/ALSA host available to CC.
  The Linux `port_specs`/`port_env` branch (`-lasound -lpthread`) is wired but
  unexercised. Re-entry: run the shell probe / `rebar3 as test check` on Linux.
  Disclosed, not dropped.
- **Row 4 — opaque resource term (S1): done (AMENDED).** Original check
  (`is_reference` false) is invalid on OTP 28 where resources are magic
  references. Amended (architect-approved) to type-checked opacity. eunit
  `open_returns_opaque_resource_test` passes; probe `is_reference=true
  foreign={caught,error,badarg}`. See ledger Amendments.
- **Row 5 — close returns ok (S2): done.** `open_close_roundtrip_test`.
- **Row 6 — double close → `{error, not_open}`, no crash (S2): done.**
  `double_close_is_tagged_error_test`.
- **Row 7 — destructor runs once on GC, no double-uninit (S1): done.**
  `gc_runs_destructor_once_test` (GC ⇒ `uninit_count` +1) and
  `explicit_close_then_gc_no_double_uninit_test` (close +1, dtor +0). No VM
  crash. Instrumentation = mutex-guarded counter in `do_uninit`
  (`c_src/midiio_nif.c:69`).
- **Row 8 — resource type opened only in `load`; `live` guards uninit (S2):
  done.** `enif_open_resource_type` sole occurrence at `c_src/midiio_nif.c:96`
  (in `load`). Both `context_close` and `dtor_context` route through
  `do_uninit`'s `res->live` check under the mutex.
- **Row 9 — mapping covers all 8 codes (S3): done.** `result_atom_mapping_test`
  asserts `0,-1…-7` → `ok,error,invalid_arg,no_backend,out_of_range,
  already_open,not_open,alloc_failed` via the `result_atom/1` introspection NIF.
- **Row 10 — `-on_load`/`-nifs`/`nif_error` stubs (S2): done.**
  `src/midiio.erl:9,11`; every stub body is `?NOT_LOADED` =
  `erlang:nif_error(nif_not_loaded)`.
- **Row 11 — `-spec` on every export (S3): done.** 5 specs (4 exports + `init/0`);
  dialyzer clean.
- **Row 12 — xref clean (S2): done.** `rebar3 xref`: zero findings, exit 0.
- **Row 13 — dialyzer clean (S2): done.** Zero warnings over 2 files. Needed
  `{plt_extra_apps, [eunit, proper]}` (additive) so the eunit-generated `test/0`
  is not flagged unknown.
- **Row 14 — eunit green (S1): done.** `All 6 tests passed.`
- **Row 15 — `rebar3 check` alias green (S1): done, with caveats.** `rebar3 as
  test check` runs compile→xref→dialyzer→eunit→coverage end-to-end, exit 0.
  Caveats (disclosed in ledger Notes): (a) must run `as test` — the `proper`
  plugin is test-scoped in the existing config; (b) cover cannot instrument
  `midiio.beam` because reload re-triggers `on_load`→`load_nif` (upgrade
  unsupported by the prescribed `ERL_NIF_INIT`); `min_coverage=0` keeps it green.
- **Row 16 — no memory error under sanitizer (S2): done, with caveat.** ASan
  harness → `ASAN-OK`, exit 0: zero use-after-free / double-free / overflow over
  200 init→uninit→double-uninit cycles + all-8 mapping checks. LeakSanitizer is
  unsupported on macOS, so **leak** detection is deferred to the Linux/valgrind
  pass (with row 3).

## Disposition summary

- 16 rows total. **Done: 14** (rows 1,2,4–16 except 3). **Deferred: 1** (row 3,
  Linux — no host). Row 16 done for memory errors, leak half deferred to Linux.
- All S1 rows closed except row 3 (Linux load), which is honestly blocked on a
  Linux host and handed forward. No S2 row left open without a disposition.
- One ledger amendment (row 4), architect-approved, fully documented.

## Disclosed deviations from the assignment

1. **Two test-only NIFs** (`result_atom/1`, `uninit_count/0`) beyond the
   prescribed two, added solely to make rows 7 and 9 eunit-verifiable as those
   rows direct. Documented as test-only; recommend gating behind `-DMIDIIO_TEST`
   in a later slice.
2. **`plt_extra_apps` added** to the dialyzer config (additive; needed for the
   unified test-profile `check` run).
3. **`.gitignore`** now excludes `priv/*.so` (build product).

## What worked

- Reading the four NIF concept cards before writing C: the resource
  alloc/make/release ordering and the magic-reference behaviour came directly
  from them, and the pre-made-atoms-in-`load` pattern dropped straight in.
- The `live`-flag + single `do_uninit` path made rows 6, 7, and 8 fall out of one
  small, mutex-guarded helper rather than three separate guards.
- Catching the OTP-28 magic-reference reality at the shell probe (before writing
  the eunit assertion) turned a silent test failure into a clean, evidence-backed
  ledger amendment.

## Not committed

These changes are in the working tree, uncommitted (on `main`). Awaiting
instruction to commit (will branch first per repo convention).
