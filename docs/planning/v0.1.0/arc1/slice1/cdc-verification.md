# CDC verification — arc1/slice1

> Independent verification by CDC (separate context from CC), with evidence
> access: I read the actual `c_src/midiio_nif.c`, `src/midiio.erl`,
> `rebar.config`, `test/midiio_tests.erl`, and `c_src/test/midiio_asan.c` — not
> CC's summary — and attempted to reproduce the deferred Linux rows in a Linux
> sandbox. Verdict per row below, then severity-classified findings.
>
> **Environment limit (disclosed up front):** the CDC sandbox is Linux/aarch64
> with `gcc` only — **no Erlang/OTP, no rebar3, no `libasound2-dev`, no
> `valgrind`, no root to install them.** So I cannot reproduce the BEAM/macOS
> runtime rows or the Linux/ALSA build here. I verify those by code+config read
> and **accept CC's macOS runtime evidence where the logic is platform-independent
> and the code supports the claim**; I mark clearly where that's the case.

## Overall verdict: **PASS** (slice is sound)

14 rows independently signed or accepted-with-evidence; 2 rows
(3, leak-half of 16) remain disclosed-deferred with a sharpened re-entry; 4
findings dispositioned (1×S2 follow-up, 3×S3). No S1 findings. The code is clean,
idiomatic, and the lifecycle logic is correct by construction.

## Per-row disposition

| # | Verdict | Basis |
|---|---------|-------|
| 1 | accepted | `rebar.config` build wiring is sound (pc, per-OS `port_specs`/`port_env`, artifacts). macOS `.so` build evidence accepted from CC; not reproduced (no OTP/rebar3 in CDC env). |
| 2 | accepted | macOS `load_nif` resolves `midiio_nif`→`.so`; consistent with `init/0` (`src/midiio.erl:26`). Runtime evidence CC's. |
| 3 | **deferred** | **Attempted in CDC sandbox; blocked** — no `libasound2-dev` (ALSA headers) and no root to install. The Linux branch (`-lasound -lpthread`, `rebar.config:29`) is verified by read but unexercised. Re-entry below. |
| 4 | **signed** | Code confirms opacity: `context()` is opaque `term()` (`midiio.erl:19`); `enif_get_resource` type-checks and `enif_make_badarg` rejects a foreign ref (`midiio_nif.c:156–157`). Amendment reasoning (magic refs in OTP 28) is **correct** — I independently concur; the test asserts exactly the right property. |
| 5 | signed (logic) | `do_uninit` returns 1→`am_ok` (`midiio_nif.c:159–160`). Platform-independent; runtime per CC. |
| 6 | signed (logic) | second close: `do_uninit` returns 0→`{error, not_open}` (`:161`). Correct. |
| 7 | **signed** | Exactly-once is correct by construction: `do_uninit` increments `g_uninit_count` and flips `live` **only when live**, all under `g_uninit_lock` (`:72–79`). Both close and dtor funnel through it. Test logic (spawn_monitor → DOWN → GC → count delta) is sound. |
| 8 | **signed** | `enif_open_resource_type` sole occurrence, inside `load` (`:96`). `live` guards uninit in the single `do_uninit` path. Confirmed by read. |
| 9 | **signed** | `result_to_atom` maps all 8 codes + `default→am_error` (`:53–63`); the 8 atoms pre-made in `load` (`:105–112`). Test asserts each (`midiio_tests.erl:32–40`). |
| 10 | **signed** | `-on_load(init/0)` (`:9`), `-nifs([...4...])` (`:11`), every stub is `?NOT_LOADED = erlang:nif_error(nif_not_loaded)` (`:21,32,38,44,50`). |
| 11 | **signed** | 5 `-spec`s covering all exports + `init/0`. Confirmed by read. |
| 12 | accepted | xref clean — accepted from CC; no undefined/unused calls visible in the small surface. |
| 13 | accepted | dialyzer clean with `{plt_extra_apps,[eunit,proper]}` (`rebar.config:44`) — a sound, additive fix (see F-none; it's correct). |
| 14 | accepted | eunit "All 6 tests passed" — accepted from CC; the 6 tests read as correct and cover rows 4–9. |
| 15 | accepted* | `rebar3 as test check` green — accepted; see **F1/F3** for the two caveats (coverage gate, `as test`). |
| 16 | accepted (mem) / **deferred (leak)** | macOS ASan memory-error pass accepted from CC. **Leak half attempted in CDC sandbox and blocked** (no ALSA headers/root → can't build the harness on Linux; ASan/LSan unavailable). Re-entry below. |

## Findings

**F1 — Coverage gate is effectively disabled. Severity: S2. Disposition: accept
for slice 1, tracked follow-up (recommend soon).**
`coverage` runs `cover --min_coverage=0` (`rebar.config:69`) because, as CC
honestly disclosed, `cover` reloads the instrumented module, which re-triggers
`-on_load` → `load_nif`, and the prescribed `ERL_NIF_INIT(midiio, …, load, NULL,
NULL, NULL)` (`midiio_nif.c:200`) supplies **no `upgrade` callback**, so the
reload fails and the module can't be instrumented. Net: the `check` alias's
coverage step is a **no-op** for `midiio.beam`. Fine for this tiny module (eunit
carries behavioural evidence), but **every future slice inherits a disabled
coverage gate** — that's a silent quality-floor erosion if left. **Recommendation:**
add an `upgrade` callback to `ERL_NIF_INIT` (and decide `reload`/`unload`) so cover
can reload the instrumented module and `min_coverage` can be raised to a real
threshold. Cheap; worth doing in arc1/slice3 or a short hygiene slice before the
module grows. *(Captured as a learning — see `NIF-LEARNINGS.md`.)*

**F2 — Test-only NIFs in the public surface. Severity: S3. Disposition: accept
(disclosed), tracked follow-up.**
`result_atom/1` and `uninit_count/0` are exported and in `-nifs`
(`midiio.erl:11,13`). They exist solely to make rows 7 and 9 eunit-verifiable
(exactly as those rows direct) and are documented as test-only — a reasonable
trade. But they ship in the public API. Concur with CC's recommendation to gate
them behind a test build (`-DMIDIIO_TEST`) in a later slice.

**F3 — `check` requires `rebar3 as test check`. Severity: S3. Disposition:
accept (pre-existing), document.**
Bare `rebar3 check` fails (`Command proper not found`) because the `proper`
plugin is `test`-profile-scoped (`rebar.config:52–53`). Pre-existing, not
introduced by this slice. Either document the `as test` invocation prominently
(README/CONTRIBUTING) or restructure so `check` works bare.

**F4 — Linux/ALSA build + leak detection unverified. Severity: S3
(environmental, not a defect). Disposition: deferred with host spec.**
Not a code problem — a CDC-environment gap. The Linux link branch is verified by
read but unexercised.

## Re-entry for the deferred rows (3, 16-leak)

A verification host needs: **Linux + Erlang/OTP 27+ + rebar3 + `libasound2-dev`**
(ALSA sequencer headers) **+ `valgrind`** (or a clang/gcc with ASan+LSan). Then:
1. `rebar3 as test check` → closes row 3 (BEAM `load_nif` on ALSA) and re-runs
   eunit on Linux.
2. Build the standalone harness on Linux and run under ASan+LSan **or** valgrind:
   `gcc -fsanitize=address -g -std=c11 c_src/test/midiio_asan.c -o /tmp/h
   -lasound -lpthread && ASAN_OPTIONS=detect_leaks=1 /tmp/h` → closes the leak
   half of row 16. *(Note: `mm_context_init` on ALSA calls `snd_seq_open`, which
   needs an ALSA sequencer device; a fully headless container without
   `/dev/snd/seq` may return `MM_ERROR` — run on a host with ALSA present.)*

## Note on the code quality (beyond the ledger)

The C is genuinely clean: atoms pre-made in `load`, the single guarded
`do_uninit` cleanup path, the correct error-path reasoning in `context_open`
(`live=0` before init so a failed init's destructor is a no-op,
`midiio_nif.c:132–140`), and `mm_context` embedded by value. The amendment to
row 4 is a real, correct catch about magic-reference resources. Nothing here
needs rework; F1 is the one thing worth addressing soon, and it's additive.
