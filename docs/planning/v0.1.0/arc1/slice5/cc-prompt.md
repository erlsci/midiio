# CC assignment — arc1/slice5: arc-1 hardening (close-out)

> Self-contained. Read the slice doc, then implement to the ledger. Six items;
> they're largely independent — do them in any order. Two (F2, the CI ALSA
> *runtime*) carry explicit disclose-defer latitude: if an item turns
> disproportionately entangled for v0.1.0, disclose it with a re-entry note rather
> than forcing it. CDC verifies on close.

## Posture

Peer-frame, write-to-the-floor. Load **collaboration-framework** and
**erlang-guidelines**. Verify each change in the real toolchain (you have OTP +
macOS; the CI item runs on push). Where a mechanism's exact behaviour is
uncertain (rebar3 cover exclusion, conditional NIF builds), **run it and report
what actually happens** rather than assuming.

## Required reading

- `docs/planning/v0.1.0/arc1/slice5/slice-doc.md` (the six items + why).
- `docs/planning/v0.1.0/arc1/slice3/cdc-verification.md` (coverage strategy) and
  the slice-1 `cdc-verification.md` (F1, F2, F3 origins).
- `rebar.config`, `c_src/midiio_nif.c`, `src/midiio.erl`, `mk/erlang.mk`,
  `.github/workflows/vendor-check.yml`, `workbench/NIF-LEARNINGS.md`.

## Item 1 — NIF-aware coverage strategy (headline)

**Goal:** the coverage gate stops eroding as NIFs are added, and measures
*real-logic* Erlang rather than the structurally-uncoverable NIF-binding module.

**Approach:** exclude `midiio` from the cover metric — rebar3 supports
`{cover_excl_mods, [midiio]}` (confirm the exact key/behaviour by running it).
With the binding module excluded there are no logic modules yet, so the gate is
dormant; set `min_coverage` to a real target (e.g. a meaningful floor) that
passes vacuously now and becomes a true gate when arc-2/3 logic modules land.
Keep `cover_enabled` + cover **reporting** on. In `rebar.config`, leave a comment
explaining: `midiio` is a NIF-binding module (mostly `?NOT_LOADED` stubs,
unreachable once the `.so` loads); its surface is verified by **eunit + ASan**,
not line %. Report the resulting `rebar3 as test check` coverage output.

*Acceptance:* adding the next NIF would **not** force lowering the floor; `check`
green; the rationale is in `rebar.config`.

## Item 2 — F2: gate the test-only NIFs  *(S3; disclose-defer latitude)*

**Goal:** `result_atom/1` and `uninit_count/0` are not in the shipped default
surface; they remain available to eunit.

**Approach:** guard the C `ErlNifFunc` entries + their function bodies with
`#ifdef MIDIIO_TEST`; add `-DMIDIIO_TEST` to the **test profile's** `port_env`
(so the test build of the `.so` includes them); guard the Erlang `-nifs`/
`-export`/stubs with `-ifdef(TEST)` (rebar3 defines `TEST` under eunit). This
implies a test-profile rebuild of the `.so` with the macro — verify both the
default build (no test NIFs) and the test build (eunit still green). **If the
two-build coordination proves disproportionate for v0.1.0, disclose-defer it**
with a re-entry note; it's S3 and the test NIFs are harmless.

## Item 3 — F3: dialyzer profile root cause + asan commit

**Goal:** a bare `rebar3 dialyzer` (default profile) works; the `make asan` fix
is committed.

**Approach:** move `{plt_extra_apps, [eunit, proper]}` from the top-level
`dialyzer` config into the **test profile's** `dialyzer` config (a default-profile
dialyzer doesn't see test modules, so it needn't know `proper`; the `as test`
path keeps the extras for the test modules it does see). Verify: bare `rebar3
dialyzer` → clean; `rebar3 as test dialyzer` and `as test check` → still clean.
The `make dialyzer` target may stay `as test` (it analyses more) — your call, just
keep it green. Commit the existing uncommitted `mk/erlang.mk` `-framework
CoreFoundation` edit (slice-4 finding #1).

## Item 4 — relocate `NIF-LEARNINGS.md`

**Goal:** the learnings log is tracked, not gitignored.

**Approach:** move `workbench/NIF-LEARNINGS.md` → a tracked path (suggest
`docs/NIF-LEARNINGS.md`; confirm it's not under a `.gitignore` rule). Update the
header note ("This is the practitioner-evidence half…") and any path references
to it (e.g. in `workbench/NIF-GUIDE-planning-prompt.md`, which is itself
gitignored — update the reference anyway for when it's used). Commit the moved
file. *(Optional, your judgement: if the upstream proposals / research notes in
`workbench/` are worth preserving too, flag them — but the learnings log is the
one that must be tracked.)*

## Item 5 — cross-platform CI

**Goal:** close the deferred-Linux pile durably (slice-1 row 3 Linux load,
slice-3 row 6 `alsa` backend, slice-1 row 16 leak-half) and keep macOS green, on
every push.

**Approach:** add a GitHub Actions workflow (e.g. `.github/workflows/ci.yml`)
with a matrix over `ubuntu-latest` + `macos-latest`: set up OTP (e.g.
`erlef/setup-beam`), install `libasound2-dev` on Linux, run `rebar3 as test
check`, and build + run the ASan harness (`make asan`; Linux ASan includes
LeakSanitizer → closes the leak half of slice-1 row 16). **Headless-ALSA
caveat:** `mm_context_init` on ALSA calls `snd_seq_open`, which needs a sequencer
device; a headless runner may lack `/dev/snd/seq`. Try `sudo modprobe snd-seq`
(or `snd-virmidi`) in the job; if the runner genuinely can't provide a
sequencer, the ALSA **runtime** rows (Linux `context_open`, the lifecycle ASan
loop) are disclosed-deferred — but the Linux **build + link + enumeration-shape +
ASan-compile** still run and are real progress. Report what the runner supports.
Keep the existing `vendor-check.yml` gate (or fold it in — your call).

## Item 6 — commit hygiene

Commit, grouped sensibly: the slice-4 build tooling (`Makefile`, `mk/erlang.mk`,
`mk/minimidio.mk`), the CDC verification docs (slices 1–3 + F1), the `ARCS.md`
updates, this slice's docs, and the changes from items 1–5. Keep attribution
clean (these are project/CDC artifacts → maintainer-authored).

## Arc-1 close-out check (do this last)

Before declaring arc 1 done: diff arc 1's **specified** capability (`ARCS.md`
Arc 1: build+load, vendoring, context lifecycle, enumeration+caps) against what
shipped across slices 1–5. Anything missing is disclosed, deferred-with-rationale,
or a silent drop (eliminate the third). Note the result in the closing report.

## Done

Every ledger row closed or disclosed-deferred with a re-entry note; `rebar3 as
test check` green with a non-eroding coverage gate; CI workflow present; arc-1
close-out check written. Five-iteration cap.
