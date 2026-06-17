# Ledger — arc1/slice5: arc-1 hardening

> CC implements + fills **CC evidence**; CDC verifies independently. Severity:
> **S1** blocker / **S2** major / **S3** minor. Items with disclose-defer latitude
> are marked. Five-iteration cap.

## Rows

| # | Item | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|------|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | Coverage | `midiio` excluded from the cover metric; gate no longer erodes as NIFs are added | `rebar.config` has `cover_excl_mods` (or equiv) excluding `midiio`; adding a hypothetical NIF would not require lowering the floor | S2 | ✅ done | `rebar.config`: `{cover_excl_mods, [midiio]}`. The binding module's % is out of the metric, so adding NIFs to it can never force the floor down (slice-3's 33%→22% erosion is ended). | |
| 2 | Coverage | cover **reporting** still on; `rebar3 as test check` green | run the alias; coverage output present, exit 0 | S2 | ✅ done | `{cover_enabled, true}` kept (test profile); `rebar3 as test check` → exit 0. Cover step runs and reports `No coverdata found` (the only module is excluded → dormant gate, passes vacuously). | |
| 3 | Coverage | rationale documented in `rebar.config` (NIF-binding module; eunit+ASan is the real gate) | read the config comment | S3 | ✅ done | `rebar.config` "Coverage strategy (NIF-aware)" comment: `midiio` is a NIF-binding module (`?NOT_LOADED` stubs unreachable once the `.so` loads); surface verified by **eunit + ASan**, not `midiio.beam` line %. | |
| 4 | F2 | test-only NIFs (`result_atom/1`, `uninit_count/0`) absent from the **default** build surface | default-profile build: the two NIFs are `#ifdef MIDIIO_TEST`-guarded (C) and `-ifdef(TEST)`-guarded (Erlang); not exported in a non-test build | S3 ⟂ | ⏸ deferred | **DISCLOSED-DEFERRED.** Attempted; the default build *did* exclude them (`result_atom` unexported, loads OK). But `pc` builds one shared `priv/*.so` + `c_src/*.o` in the source tree across profiles, so default-then-`as test` reuses the stale `.so` → `load_nif` mismatch (order-dependent). Reverted to keep `check` reliably green. **Re-entry:** per-profile `.so` artifact (or test pre-hook force-rebuild), then re-apply the guards — see closing report + in-code notes. S3, test NIFs harmless. | |
| 5 | F2 | eunit still green (test build includes them) | `rebar3 eunit` → all pass; rows 7/9 of slice 1 still exercised | S3 ⟂ | ✅ done | `rebar3 as test check` → `All 12 tests passed` (incl. `result_atom_mapping_test`, the GC `uninit_count` tests). With F2 reverted the test NIFs are always present, so the eunit coverage of slice-1 rows 7/9 is intact. | |
| 6 | F3 | bare `rebar3 dialyzer` (default profile) succeeds | run it → exit 0, no "Could not find application: proper" | S2 | ✅ done | `rebar3 dialyzer` → exit 0, "Analyzing 1 files" (src only), no "Could not find application: proper". | |
| 7 | F3 | `rebar3 as test dialyzer` and `as test check` still clean | run both → zero warnings | S2 | ✅ done | `rebar3 as test dialyzer` → exit 0, "Analyzing 2 files", zero warnings; `as test check` → exit 0. | |
| 8 | F3 | `plt_extra_apps` scoped to the test profile (not top-level) | code read `rebar.config` | S3 | ✅ done | `rebar.config`: top-level `dialyzer` has only `{warnings,[unknown]}`; `{plt_extra_apps,[eunit,proper]}` is in the **test profile's** `dialyzer`. | |
| 9 | F3 | `make asan` `-framework CoreFoundation` edit committed | `git log`/`git show` shows the `mk/erlang.mk` edit committed | S3 | ✅ done | `git log -1 -- mk/erlang.mk` → `e75a490 "Slice 5 updates"`; `grep CoreFoundation mk/erlang.mk` → present (line 107). Already committed before this slice. | |
| 10 | Learnings | `NIF-LEARNINGS.md` moved to a tracked path; not gitignored | `git ls-files` lists it (e.g. `docs/NIF-LEARNINGS.md`); `git check-ignore` says not ignored | S3 | ✅ done | Moved `workbench/NIF-LEARNINGS.md` → `docs/NIF-LEARNINGS.md`; `git check-ignore docs/NIF-LEARNINGS.md` → not ignored; committed (this slice). | |
| 11 | Learnings | path references updated | grep for the old `workbench/NIF-LEARNINGS.md` path; references point at the new location | S3 | ✅ done | Updated `workbench/NIF-LEARNINGS.md`→`docs/NIF-LEARNINGS.md` in the F1 docs + `workbench/NIF-GUIDE-planning-prompt.md`; header note updated. Remaining old-path mentions are in this slice's cc-prompt/ledger, which *describe* the move. | |
| 12 | CI | workflow present with ubuntu + macos; runs `rebar3 as test check` | read `.github/workflows/ci.yml`; matrix has both OSes | S2 | ✅ done | `.github/workflows/ci.yml`: matrix `ubuntu-latest` + `macos-latest`, `setup-beam`, `rebar3 as test check`, `make asan`. macOS leg's commands verified green locally. | |
| 13 | CI | **Linux load closes slice-1 row 3** — `context_open` works on ALSA in CI (or disclosed-deferred with the headless-ALSA reason) | CI run green on ubuntu, or a disclosed note on the seq-device limitation + what *did* run (build/link/enum/ASan-compile) | S2 ⟂ | ⏸ deferred | **DISCLOSED-DEFERRED (pending first CI push).** CC is macOS-only — cannot run GitHub Actions locally. The workflow loads `snd-virmidi` best-effort and runs `context_open` on Linux; it closes row 3 **if** the runner provides a sequencer, else the runtime defers while Linux build/link/enum still run. Re-entry: the first push of `ci.yml`. | |
| 14 | CI | ASan + LeakSanitizer run on Linux (closes slice-1 row 16 leak-half) — or disclosed-deferred with reason | CI builds + runs `make asan` on ubuntu; LSan clean, or disclosed | S2 ⟂ | ⏸ deferred | **DISCLOSED-DEFERRED (pending first CI push).** `make asan` runs on the Linux leg (LSan is on by default there); the lifecycle loop needs a sequencer (`mm_context_init`→`snd_seq_open`), same `snd-virmidi` dependency as row 13. Verified on first push. | |
| 15 | CI | `alsa` backend atom verified on Linux (closes slice-3 row 6) — or disclosed | CI eunit on ubuntu asserts `caps` backend `=> alsa`, or disclosed | S3 ⟂ | ⏸ deferred | **DISCLOSED-DEFERRED (pending first CI push).** The eunit `caps_backend_and_flags_test` already branches on backend; on the Linux leg it will assert `alsa` once a context opens (snd-virmidi). Verified on first push. | |
| 16 | Commit | slice-4 tooling, CDC docs, ARCS updates, this slice committed | `git log` / `git status` clean | S3 | ✅ done | slice-4 tooling + CDC docs + ARCS committed earlier (`d89ad6b`, `606aeaa`, `e75a490`); this slice's changes committed grouped (see commit log); `git status` clean post-commit. | |
| 17 | Close-out | arc-1 specified capability diffed vs delivered; no silent drops | the close-out check is written (closing report); any gap disclosed/deferred | S2 | ✅ done | `closing-report.md` "Arc-1 close-out check" table: every specified capability mapped to delivered evidence. Two disclosed gaps (Linux runtime → first CI push; F2 → S3 deferred); **no silent drops**. | |

*(⟂ = disclose-defer latitude: F2 rows 4–5 if the dual-build is disproportionate; CI rows 13–15 if the runner can't provide an ALSA sequencer.)*

## Notes

- **Item 1 mechanism:** confirm rebar3's exact cover-exclusion behaviour by
  running it (with `midiio` the only module, an excluded set may make the metric
  vacuous — that's fine and is the point; the floor becomes real when logic
  modules arrive). Don't assert the key from memory; report what the run shows.
- **Headless ALSA (CI):** `snd_seq_open` needs a sequencer device; try `modprobe
  snd-seq`/`snd-virmidi`. If unavailable, the Linux runtime rows are disclosed —
  still strictly more than today (today: nothing runs on Linux).
- The deferred-Linux rows in slices 1 and 3 should be updated to point at this
  slice's CI as their re-entry (or closed if CI exercises them).

## Closing

On close, CC writes `closing-report.md` (incl. the arc-1 close-out diff); CDC
writes `cdc-verification.md`. Done when all S1/S2 rows close or carry a written
disposition, and the coverage gate provably no longer erodes.
