# CDC verification — arc1/slice5 (arc-1 hardening) + arc-1 close

> Independent verification (offline-capable checks run in a Linux sandbox: git,
> grep, config read; OTP-dependent runs accepted on CC's macOS evidence where the
> config supports the claim). Verdict: **PASS.** Arc 1 is **CDC-closed** with two
> carried-forward threads (below).

## Independently confirmed

- **Coverage (rows 1–3):** `rebar.config` has `{cover_excl_mods, [midiio]}` (`:44`)
  + `min_coverage=80` (`:99`) + the NIF-aware rationale comment (`:34–40`). The
  binding module is out of the metric, so adding NIFs to it can never force the
  floor down — the 33%→22% erosion is **structurally ended**. Confirmed by read.
- **F2 reverted cleanly (rows 4–5):** the *only* `MIDIIO_TEST` traces are
  explanatory comments (`midiio_nif.c:237`, `rebar.config:76,81`) — no stray
  `#ifdef` guards, no `-DMIDIIO_TEST` in `port_env`. The test NIFs
  (`result_atom/1`, `uninit_count/0`) are present in `nif_funcs` (`:348–349`), so
  eunit's slice-1 row-7/9 coverage is intact. The revert is complete, not partial.
- **F3 (rows 6–8):** `plt_extra_apps` is in the **test profile's** `dialyzer`
  (`:75`); the top-level `dialyzer` carries only `{warnings,[unknown]}`. So a
  default-profile `rebar3 dialyzer` no longer needs `proper`. Config structure is
  correct (bare-run accepted on CC's macOS evidence).
- **Learnings (rows 10–11):** `docs/NIF-LEARNINGS.md` is git-tracked;
  `git check-ignore` confirms **not ignored**.
- **CI (rows 12–15):** `.github/workflows/ci.yml` has the ubuntu+macos matrix,
  `setup-beam`, `libasound2-dev`, best-effort `snd-virmidi`, `rebar3 as test
  check`, `make asan`. Present and well-structured.
- **Commits (16) + close-out (17):** tree clean; commits grouped; the
  `closing-report.md` close-out table maps every Arc-1 capability to delivered
  evidence with no silent drops.

## CC's F2 finding — endorsed

The disclosure is sound and the finding is genuinely useful: `pc` builds **one
shared `.so` in the source tree across profiles**, so a test-only NIF set makes
`load_nif` order-dependent (default compile → `as test` reuses the stale `.so`
→ arity mismatch). Reverting to keep `check` reliably green was the right call for
an S3 item; the per-profile-`.so` re-entry is recorded. *(Worth a `NIF-LEARNINGS`
entry — see recommendation.)*

## CDC note — the gate is intentionally dormant (watch in arc 2)

With `midiio` excluded and no other modules, the cover gate **passes vacuously**
("No coverdata found"). This is correct per L17 — there is no meaningful Erlang
line-coverage to gate yet, and the real verification is eunit (12 tests) + ASan.
But it means there is *effectively no line-coverage gate active right now.*
**To verify in arc 2:** when the first pure-Erlang logic module lands (the
per-device `gen_server`/helpers), confirm the `80` floor actually **engages**
(i.e. cover finds coverdata and gates it) rather than staying dormant. Trending
item, not a defect.

## Recommendation (small)

Add a `NIF-LEARNINGS.md` entry for the `pc`-single-`.so`-across-profiles gotcha
(why conditional/test-only NIF compilation is harder than `-ifdef` suggests under
rebar3+pc) — it's a real `[GAP]` earned here.

## Arc-1 close — carried-forward threads

Arc 1's capability is delivered and evidenced on macOS; **CDC-closed.** Two open
threads travel forward, both disclosed with re-entry (neither blocks arc 2):

1. **Linux runtime verification** — slice-1 row 3 (load), slice-3 row 6 (`alsa`
   backend), slice-1 row 16 (leak via LSan). Mechanism (CI) in place; **closes on
   the first push** if the runner provides an ALSA sequencer. *Action: watch the
   first CI run; if `snd-virmidi` is unavailable on the runner, decide whether to
   add a service container or accept the runtime rows as standing-deferred.*
2. **F2 test-NIF gating** — S3, deferred; re-entry is a per-profile `.so` when a
   build refactor or arc-2 NIF growth makes it proportionate.
