# Ledger — arc3/slice2: set_owner handoff hardening + virtual-loopback conformance

> CC implements + fills **CC evidence**; CDC verifies independently with evidence
> access. Severity: **S1** blocker / **S2** major / **S3** minor. The bytes⇄message
> conformance rows are where a silent corruption hides — assert exact bytes, not
> "a message arrived." Disclosed expected-fails (U1–U3/S1) are a **pass** when
> tagged with the upstream reference. Five-iteration cap.

## Group A — `set_owner` ownership-handoff hardening (R1/R2, slice-1 re-verification)

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 1 | **R2 closed:** `set_owner` arms the new monitor (into a local `ErlNifMonitor`) **before** demonitoring the old; commits owner+monitor only on success | code read: monitor-new-then-demonitor-old ordering; no path leaves a started input with a dead owner and `monitored==0` | S3 | ✅ done | `set_owner` (`midiio_nif.c:762`): for inputs, `enif_monitor_process(env, res, &pid, &new_mon)` into a LOCAL `new_mon` first (`:779`); only on success demonitor old + store `new_mon` + `monitored=1` (`:783–786`); on failure unlock with the old owner/monitor untouched and return `{error, owner_not_alive}` (`:780–781`). No path leaves a dead owner with `monitored==0`. | |
| 2 | Handoff to an **already-dead** pid returns `{error, owner_not_alive}` and leaves the **old owner + monitor fully intact** (device still serves it) | eunit: `set_owner(In, DeadPid)` → `{error, owner_not_alive}`; then kill the *old* owner → device reclaimed (`uninit_count` +1). No leak, no silent `ok` | S3 | ✅ done | eunit `set_owner_dead_handoff_preserves_old_owner_test_`: in a child, `set_owner(In, Dead)` → `{error, owner_not_alive}`; the child (old owner) then dies and its **still-armed** monitor reclaims (`uninit_count` +1 within 5 s). No leak, no silent `ok`. | |
| 3 | Handoff to a **live** pid re-points ownership: the **new** owner's death reclaims the device | eunit: `set_owner(In, P2)` → `ok`; `P2` dies without stop/close → `uninit_count` +1 within a window | S3 | ✅ done | eunit `set_owner_live_handoff_redirects_reclaim_test_`: `set_owner(In, P2)` → `ok`; `P2` dies without stop/close → `uninit_count` +1. | |
| 4 | **R1 narrowed:** the only residual handoff-vs-death race is the irreducible ERTS demonitor window (death already in delivery); still no UAF | code read: idempotent `do_dev_cleanup` covers the race; note the residual floor in the closing report | S3 | ✅ done | With monitor-new-before-demonitor-old, a successful re-point installs the new monitor before dropping the old; a racing old-owner death after that hits the (guarded, idempotent) `do_dev_cleanup` once — no UAF. The residual is only the unavoidable ERTS window (a death already in delivery when we demonitor); noted in the closing report. | |
| 5 | `am_owner_not_alive` atom declared + made in `init_statics`; `set_owner/2` `-spec` + moduledoc updated for the new error return | code read + `rebar3 as test check` (dialyzer) green | S3 | ✅ done | `am_owner_not_alive` declared (`midiio_nif.c:99`), made in `init_statics` (`:310`). `src/midiio.erl`: `-spec set_owner(device(), pid()) -> ok | {error, owner_not_alive}` + `@doc` ownership/handoff contract. dialyzer (3 files) clean in `rebar3 as test check`. | |
| 6 | *(optional)* `down_device`'s `monitored=0` write taken under `res->lock` (not while calling `do_dev_cleanup`); or skipped-and-disclosed | code read: the lock is held only around the flag write, released before cleanup | S3 | ⏸ skipped | **Disclosed-skipped (optional S3).** `down_device`'s `res->monitored = 0` write is left unlocked — a benign int race with `set_owner` (the monitor has already fired when `down` runs, so the worst case is a redundant demonitor that returns non-zero harmlessly). Taking the lock there adds a lock/unlock on the death path for no memory-safety gain; left as-is, noted. | |

## Group B — virtual-loopback conformance + PropEr (the proof; no new public surface)

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 7 | Virtual source + virtual destination in one VM; the loopback harness sends and the owner receives `{midi_in, Dev, <<Bytes>>, TsNanos}` | eunit (vm-test/macOS): the harness opens both, sends, receives — headless-skippable if no virtual backend | S1 | ✅ done | eunit `with_loopback` harness (virtual `open_output_virtual` source + real `open_input` connected to it) — the owner receives `{midi_in, Dev, <<Bytes>>, Ts}`; used by all Group B/C delivery tests. Skips cleanly when no virtual source is enumerable. | |
| 8 | **Full taxonomy byte-exact:** Note Off/On, Poly-AT, CC, Program Change, Channel-AT, Pitch Bend, Song Position, Song Select, Tune Request, real-time (Clock/Start/Continue/Stop/Active-Sensing/Reset) each round-trip with **identical bytes** | eunit: per-type assert `Bytes == Sent`; table-driven over the taxonomy | S1 | ✅ done | eunit `taxonomy_byte_exact_loopback_test_` (table-driven over `taxonomy/0` — all listed types): each `?assertEqual(Sent, Got)` over the loopback. Green on macOS/CoreMIDI. | |
| 9 | **14-bit intact:** Pitch Bend + Song Position with LSB≠MSB survive byte-exact (no LSB/MSB swap or truncation) | eunit: a value like Pitch Bend `E0 7F 3F` round-trips exactly | S2 | ✅ done | Taxonomy includes Pitch Bend `<<16#E0,16#7F,16#3F>>` and Song Position `<<16#F2,16#10,16#20>>` (LSB≠MSB) — both round-trip byte-exact. Also covered by the PropEr property (14-bit generators). | |
| 10 | **SysEx byte-exact** across several lengths (short, mid — below the U1 cap) | eunit: `F0 … F7` of varied lengths arrive identical | S2 | ✅ done | Taxonomy includes a 6-byte and a 35-byte SysEx — both arrive identical. PropEr generates SysEx of varied lengths (all byte-exact through the seams). | |
| 11 | **PropEr** bytes⇄message round-trip across **both** seams: no dropped status, correct data-byte count, 14-bit intact, SysEx varied-length byte-exact (closes arc2/slice2's deferred property) | run the PropEr suite under `as test`; converges, no shrunk counterexample | S1 | ✅ done | `test/midiio_prop.erl` `prop_seam_roundtrip` over the `seam_roundtrip/1` test NIF (both seams purely: `midiio_bytes_to_msg` → `midiio_msg_to_bytes`). `rebar3 as test proper -m midiio_prop` → **OK: Passed 100 tests**; also run under eunit (`seam_roundtrip_property_test_`, 300 numtests) so it gates in `check`. No counterexample. | |

## Group C — upstream quirk cases (each green OR a disclosed expected-fail w/ reference)

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 12 | **U1** — large SysEx (> ~256 B) over a CoreMIDI virtual source: tagged **expected-fail/skip on CoreMIDI** with the U1 ref; asserted to pass on ALSA (vm-test) if it does | read the tagged case; CI does not silently fail | S2 | ✅ done | eunit `u1_large_sysex_virtual_cap_test_` (400-byte SysEx): on **CoreMIDI** asserts `{error, _}` (the ~256 B virtual-source cap, U1 — tracked, not silent); on **ALSA** asserts byte-exact round-trip if the send succeeds. Backend-branched via `caps`. | |
| 13 | **S1** — inbound SysEx spanning more than one packet: a case that asserts one intact `F0…F7`; if it truncates, **S1 confirmed** and disclosed (repro + ref), not papered over | read the case + its disposition (green or disclosed-confirmed) | S2 | ✅ done | eunit `s1_multipacket_inbound_sysex_test_` (1000-byte SysEx): on **CoreMIDI** not-reproducible (blocked by U1's send-side cap on the virtual source — disclosed); on **ALSA** asserts one intact `F0…F7` arrives (a split/truncation would confirm S1). The ALSA assertion runs on vm-test. | |
| 14 | **U2 / R6** — `9n nn 00` delivered **as sent** (midiio does not fold vel-0 to note-off); ALSA backend-fold divergence disclosed if present | eunit: assert pass-through on the backend under test; note any backend fold | S2 | ✅ done | eunit `u2_vel0_passthrough_test_`: on **CoreMIDI** asserts `<<16#90,60,0>>` arrives **as sent** (no fold). On **ALSA** accepts either pass-through or the backend-folded `<<16#80,60,0>>` (the U2 backend inconsistency, disclosed) — midiio itself never folds. PropEr also confirms the seams don't fold vel-0. | |
| 15 | **U3** — real-time `F8` interleaved mid-SysEx (CoreMIDI): green, or disclosed expected-fail (upstream), or marked not-reproducible-headless with the U3 ref | read the case + disposition | S3 | ✅ done | eunit `u3_realtime_in_sysex_test_`: **not reproducible over the CoreMIDI virtual loopback** — observed `[<<F0,7E,F7>>, <<F8>>, <<>>]`: CoreMIDI's send path splits the real-time byte out before the read-proc sees it, so the read-proc absorption defect (`minimidio.h:748–751`) doesn't manifest. Asserts the invariant that holds (no delivered SysEx absorbed the F8). Tracked as U3 (still real for real-hardware combined packets; resolved by raw inbound framing). | |

## Group D — gates + close-out

| # | Acceptance criterion | How to verify | Sev | Status | CC evidence | CDC verdict |
|---|----------------------|---------------|-----|--------|-------------|-------------|
| 16 | All tests green on `make vm-test` (ALSA) and the host; `rebar3 as test check` green; `make asan` `ASAN-OK` | run all three; record counts | S1 | ✅ done | Host (macOS): `rebar3 as test check` → exit 0, **41 eunit tests** + the PropEr property, dialyzer (3 files) clean, coverage dormant; `make asan` → `ASAN-OK`. **`make vm-test`** (Ubuntu 24.04, real ALSA): `rebar3 as test check && make asan` → **All 41 tests passed + ASAN-OK** (the ALSA branches of U1/U2/S1 + the taxonomy ran on real ALSA). | |
| 17 | **Arc 3 + v0.1.0 planning close-out:** `PROJECT-DEFINITION.md` success criteria all met or explicitly-deferred-with-rationale; specified-vs-delivered diff across arcs shows no silent drops | read the closing report against the criteria list | S1 | ✅ done | `closing-report.md` "Close-out" section maps all 5 `PROJECT-DEFINITION.md` success criteria to delivered evidence (build+load macOS+Linux; enumerate/open/send arrives; inbound byte-exact; crashing owner leaks no handle — outputs *and* inputs; U1–U3 conformance green-or-disclosed) and walks the specified-vs-delivered diff across arcs 1–3 — **no silent drops**. | |
| 18 | `closing-report.md` written; any new `NIF-LEARNINGS` captured (e.g., the monitor-new-before-demonitor-old handoff rule) | read both | S3 | ✅ done | `closing-report.md` written; `docs/NIF-LEARNINGS.md` **L22** (atomic monitor handoff: arm the new monitor into a local before demonitoring the old). | |

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
