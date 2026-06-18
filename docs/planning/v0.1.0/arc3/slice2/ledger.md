# Ledger — arc3/slice2: set_owner handoff hardening + virtual-loopback conformance

> CC implements + fills **CC evidence**; CDC verifies independently with evidence
> access. Severity: **S1** blocker / **S2** major / **S3** minor. The bytes⇄message
> conformance rows are where a silent corruption hides — assert exact bytes, not
> "a message arrived." Disclosed expected-fails (U1–U3/S1) are a **pass** when
> tagged with the upstream reference. Five-iteration cap.

## Group A — `set_owner` ownership-handoff hardening (R1/R2, slice-1 re-verification)

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | **R2 closed:** `set_owner` arms the new monitor (into a local `ErlNifMonitor`) **before** demonitoring the old; commits owner+monitor only on success | code read: monitor-new-then-demonitor-old ordering; no path leaves a started input with a dead owner and `monitored==0` | S3 | ☐ | | |
| 2 | Handoff to an **already-dead** pid returns `{error, owner_not_alive}` and leaves the **old owner + monitor fully intact** (device still serves it) | eunit: `set_owner(In, DeadPid)` → `{error, owner_not_alive}`; then kill the *old* owner → device reclaimed (`uninit_count` +1). No leak, no silent `ok` | S3 | ☐ | | |
| 3 | Handoff to a **live** pid re-points ownership: the **new** owner's death reclaims the device | eunit: `set_owner(In, P2)` → `ok`; `P2` dies without stop/close → `uninit_count` +1 within a window | S3 | ☐ | | |
| 4 | **R1 narrowed:** the only residual handoff-vs-death race is the irreducible ERTS demonitor window (death already in delivery); still no UAF | code read: idempotent `do_dev_cleanup` covers the race; note the residual floor in the closing report | S3 | ☐ | | |
| 5 | `am_owner_not_alive` atom declared + made in `init_statics`; `set_owner/2` `-spec` + moduledoc updated for the new error return | code read + `rebar3 as test check` (dialyzer) green | S3 | ☐ | | |
| 6 | *(optional)* `down_device`'s `monitored=0` write taken under `res->lock` (not while calling `do_dev_cleanup`); or skipped-and-disclosed | code read: the lock is held only around the flag write, released before cleanup | S3 | ☐ | | |

## Group B — virtual-loopback conformance + PropEr (the proof; no new public surface)

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 7 | Virtual source + virtual destination in one VM; the loopback harness sends and the owner receives `{midi_in, Dev, <<Bytes>>, TsNanos}` | eunit (vm-test/macOS): the harness opens both, sends, receives — headless-skippable if no virtual backend | S1 | ☐ | | |
| 8 | **Full taxonomy byte-exact:** Note Off/On, Poly-AT, CC, Program Change, Channel-AT, Pitch Bend, Song Position, Song Select, Tune Request, real-time (Clock/Start/Continue/Stop/Active-Sensing/Reset) each round-trip with **identical bytes** | eunit: per-type assert `Bytes == Sent`; table-driven over the taxonomy | S1 | ☐ | | |
| 9 | **14-bit intact:** Pitch Bend + Song Position with LSB≠MSB survive byte-exact (no LSB/MSB swap or truncation) | eunit: a value like Pitch Bend `E0 7F 3F` round-trips exactly | S2 | ☐ | | |
| 10 | **SysEx byte-exact** across several lengths (short, mid — below the U1 cap) | eunit: `F0 … F7` of varied lengths arrive identical | S2 | ☐ | | |
| 11 | **PropEr** bytes⇄message round-trip across **both** seams: no dropped status, correct data-byte count, 14-bit intact, SysEx varied-length byte-exact (closes arc2/slice2's deferred property) | run the PropEr suite under `as test`; converges, no shrunk counterexample | S1 | ☐ | | |

## Group C — upstream quirk cases (each green OR a disclosed expected-fail w/ reference)

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 12 | **U1** — large SysEx (> ~256 B) over a CoreMIDI virtual source: tagged **expected-fail/skip on CoreMIDI** with the U1 ref; asserted to pass on ALSA (vm-test) if it does | read the tagged case; CI does not silently fail | S2 | ☐ | | |
| 13 | **S1** — inbound SysEx spanning more than one packet: a case that asserts one intact `F0…F7`; if it truncates, **S1 confirmed** and disclosed (repro + ref), not papered over | read the case + its disposition (green or disclosed-confirmed) | S2 | ☐ | | |
| 14 | **U2 / R6** — `9n nn 00` delivered **as sent** (midiio does not fold vel-0 to note-off); ALSA backend-fold divergence disclosed if present | eunit: assert pass-through on the backend under test; note any backend fold | S2 | ☐ | | |
| 15 | **U3** — real-time `F8` interleaved mid-SysEx (CoreMIDI): green, or disclosed expected-fail (upstream), or marked not-reproducible-headless with the U3 ref | read the case + disposition | S3 | ☐ | | |

## Group D — gates + close-out

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 16 | All tests green on `make vm-test` (ALSA) and the host; `rebar3 as test check` green; `make asan` `ASAN-OK` | run all three; record counts | S1 | ☐ | | |
| 17 | **Arc 3 + v0.1.0 planning close-out:** `PROJECT-DEFINITION.md` success criteria all met or explicitly-deferred-with-rationale; specified-vs-delivered diff across arcs shows no silent drops | read the closing report against the criteria list | S1 | ☐ | | |
| 18 | `closing-report.md` written; any new `NIF-LEARNINGS` captured (e.g., the monitor-new-before-demonitor-old handoff rule) | read both | S3 | ☐ | | |

## Notes

- **Group A is small and goes first** — it's a focused robustness fix folded in
  from the slice-1 re-verification (the `set_owner` residuals), not new feature
  surface. Severity S3 throughout: narrow, memory-safe, off the normal lifecycle —
  but worth closing before `undermidi` exercises ownership handoff on hot reload.
- **Disclosed expected-fail = pass.** U1/U3 (and possibly S1) are upstream defects;
  this slice's job is to *prove and track* them, not fix them. The native `mm_*_raw`
  swap (which resolves U2/U3 by construction) lands separately when the maintainer
  ships — the seam is ready and nothing above it changes.
- **Conformance is byte-level**, deliberately not through `midilib` (R7).

## Close-out

CC writes `closing-report.md`; CDC re-verifies independently (the byte-exact
assertions and the two `set_owner` handoff tests are the load-bearing evidence).
Done when Group A is closed, the taxonomy round-trips byte-exact, the quirk cases
are green-or-disclosed, the gates pass — **and arc 3 / v0.1.0 planning closes**.
